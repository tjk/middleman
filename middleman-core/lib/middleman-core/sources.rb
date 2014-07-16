# Watcher Library
require 'listen'

require 'middleman-core/contracts'

module Middleman
  SourceFile = Struct.new :relative_path, :full_path, :directory, :type

  class Sources
    extend Forwardable
    include Contracts

    attr_reader :app, :directories, :options

    def_delegator :@app, :logger

    TYPES = Set.new [:source, :data, :locales, :ruby, :config]

    def initialize(app, options={}, directories=Set.new)
      @app = app
      @directories = directories
      @options = options

      @on_change_callbacks = Set.new
      @on_delete_callbacks = Set.new

      @ignores = {}

      @running = false

      @update_count = 0
      @last_update_count = -1
    end

    def bump_count
      @update_count += 1
    end

    # Add a proc to ignore paths
    Contract Symbol, Symbol, Or[Regexp, Proc] => Any
    def ignore(name, type, regex=nil, &block)
      @ignores[name] = { type: type, validator: (block_given? ? block : regex) }

      bump_count
      find_new_files! if @running
    end

    # Whether this path is ignored
    # @param [Pathname] path
    # @return [Boolean]
    Contract IsA['Middleman::SourceFile'] => Bool
    def globally_ignored?(file)
      @ignores.values.any? do |descriptor|
        ((descriptor[:type] == :all) || (file[:type] == descriptor[:type])) &&
        matches?(descriptor[:validator], file)
      end
    end

    Contract Or[Regexp, RespondTo[:call]], IsA['Middleman::SourceFile'] => Bool
    def matches?(validator, file)
      path = file[:relative_path]
      if validator.is_a? Regexp
        !!validator.match(path.to_s)
      else
        !!validator.call(path, @app)
      end
    end

    Contract Symbol, String, Maybe[Hash] => And[RespondTo[:changed], RespondTo[:deleted]]
    def watch(type, path, options={})
      handler = if type.is_a? SourceDirectory
        type
      else
        SourceDirectory.new(self, type, path, options)
      end

      @directories << handler

      handler.changed(&method(:did_change))
      handler.deleted(&method(:did_delete))

      handler.poll_once! if @running

      handler
    end

    Contract And[RespondTo[:changed], RespondTo[:deleted]] => Any
    def unwatch(watcher)
      @directories.delete(watcher)

      watcher.unwatch

      bump_count
    end

    Contract Symbol => ::Middleman::Sources
    def by_type(type)
      self.class.new @app, @options, @directories.select { |d| d.type == type }
    end

    Contract None => Any
    def start!
      start_listeners!
      @running = true
    end

    # Expensive?
    Contract None => ArrayOf[IsA['Middleman::SourceFile']]
    def files
      @directories.map { |d| d.files }.flatten
    end

    Contract Symbol, String => Maybe[IsA['Middleman::SourceFile']]
    def find(type, path)
      @directories
          .select { |d| d.type == type }
          .map { |d| d.find(path) }
          .first
    end

    Contract Symbol, String => Bool
    def exists?(type, path)
      @directories.select { |d| d.type == type }.any? { |d| d.exists?(path) }
    end

    Contract None => Any
    def find_new_files!
      return unless @update_count != @last_update_count

      @last_update_count = @update_count
      @directories.each(&:poll_once!)
    end

    Contract None => Any
    def start_listeners!
      @directories.each(&:listen!)
    end

    Contract None => Any
    def stop!
      stop_listeners!
      @running = false
    end

    Contract None => Any
    def stop_listeners!
      @directories.each(&:stop_listener!)
    end

    # Add callback to be run on file change
    #
    # @param [nil,Regexp] matcher A Regexp to match the change path against
    # @return [Array<Proc>]
    Contract Proc => SetOf[Proc]
    def changed(&block)
      @on_change_callbacks << block
      @on_change_callbacks
    end

    # Add callback to be run on file deletion
    #
    # @param [nil,Regexp] matcher A Regexp to match the deleted path against
    # @return [Array<Proc>]
    Contract Proc => SetOf[Proc]
    def deleted(&block)
      @on_delete_callbacks << block
      @on_delete_callbacks
    end

    protected

    # Notify callbacks that a file changed
    #
    # @param [Pathname] path The file that changed
    # @return [void]
    Contract IsA['Middleman::SourceFile'] => Any
    def did_change(file)
      bump_count
      run_callbacks(@on_change_callbacks, file)
    end

    # Notify callbacks that a file was deleted
    #
    # @param [Pathname] path The file that was deleted
    # @return [void]
    Contract IsA['Middleman::SourceFile'] => Any
    def did_delete(file)
      bump_count
      run_callbacks(@on_delete_callbacks, file)
    end

    # Notify callbacks for a file given an array of callbacks
    #
    # @param [Pathname] path The file that was changed
    # @param [Symbol] callbacks_name The name of the callbacks method
    # @return [void]
    Contract Set, SourceFile => Any
    def run_callbacks(callbacks, file)
      callbacks.each do |callback|
        callback.call(file)
      end
    end
  end

  class SourceDirectory
    extend Forwardable
    include Contracts

    def_delegators :@parent, :app, :globally_ignored?
    def_delegator :app, :logger

    attr_reader :type

    def initialize(parent, type, directory, options={})
      @parent = parent

      @type = type
      @directory = Pathname(directory)

      @files = {}

      @validator = options.fetch(:validator, proc { true })
      @ignored = options.fetch(:ignored, proc { false })

      @disable_watcher = app.build? || @parent.options.fetch(:disable_watcher, false)
      @force_polling = @parent.options.fetch(:force_polling, false)
      @latency = @parent.options.fetch(:latency, nil)

      @listener = nil

      @on_change_callbacks = Set.new
      @on_delete_callbacks = Set.new

      @waiting_for_existence = !@directory.exist?
    end

    Contract String => Any
    def update_path(directory)
      @directory = Pathname(directory)

      stop_listener! if @listener

      @files.each do |k, _|
        remove(k)
      end

      poll_once!

      listen! unless @disable_watcher
    end

    Contract None => Any
    def unwatch
      stop_listener!
    end

    Contract None => ArrayOf[IsA['Middleman::SourceFile']]
    def files
      @files.values.uniq
    end

    Contract Or[String, Pathname] => Maybe[IsA['Middleman::SourceFile']]
    def find(path)
      p = Pathname(path)

      return false if p.absolute? && !p.to_s.start_with?(@directory.to_s)

      p = @directory + p if p.relative?

      @files[p]
    end

    Contract Or[String, Pathname] => Bool
    def exists?(path)
      !find(path).nil?
    end

    Contract None => Any
    def listen!
      return if @disable_watcher || @listener || @waiting_for_existence

      config = { force_polling: @force_polling }
      config[:latency] = @latency if @latency

      @listener = ::Listen.to(@directory.to_s, config, &method(:on_listener_change))
      @listener.start
    end

    Contract None => Any
    def stop_listener!
      return unless @listener

      @listener.stop
      @listener = nil
    end

    Contract Array, Array, Array => Any
    def on_listener_change(modified, added, removed)
      (modified + added).each(&method(:update))
      removed.each(&method(:remove))
    end

    # Manually trigger update events
    # @return [void]
    Contract None => Any
    def poll_once!
      subset = @files.keys

      ::Middleman::Util.all_files_under(@directory.to_s).each do |filepath|
        subset.delete(filepath)
        update(filepath)
      end

      subset.each(&method(:remove))

      return unless @waiting_for_existence && @directory.exist?

      @waiting_for_existence = false
      listen!
    end

    Contract Pathname => Any
    def update(path)
      descriptor = path_to_source_file(path)

      return unless valid?(descriptor)

      @files[path] = descriptor

      logger.debug "== Change (#{@type}): #{descriptor[:relative_path]}"

      run_callbacks(@on_change_callbacks, descriptor)
    end

    Contract Pathname => Any
    def remove(path)
      return unless @files.key?(path)

      descriptor = @files[path]
      return unless valid?(descriptor)

      @files.delete(path)

      logger.debug "== Deletion (#{@type}): #{descriptor[:relative_path]}"

      run_callbacks(@on_delete_callbacks, descriptor)
    end

    Contract IsA['Middleman::SourceFile'] => Bool
    def valid?(file)
      @validator.call(file) &&
      !globally_ignored?(file) &&
      !@ignored.call(file)
    end

    Contract Pathname => IsA['Middleman::SourceFile']
    def path_to_source_file(path)
      SourceFile.new(relative_path(path), path, @directory, @type)
    end

    Contract Pathname => Pathname
    def relative_path(path)
      path.relative_path_from(@directory)
    end

    # Add callback to be run on file change
    #
    # @param [nil,Regexp] matcher A Regexp to match the change path against
    # @return [Array<Proc>]
    Contract Proc => SetOf[Proc]
    def changed(&block)
      @on_change_callbacks << block
      @on_change_callbacks
    end

    # Add callback to be run on file deletion
    #
    # @param [nil,Regexp] matcher A Regexp to match the deleted path against
    # @return [Array<Proc>]
    Contract Proc => SetOf[Proc]
    def deleted(&block)
      @on_delete_callbacks << block
      @on_delete_callbacks
    end

    protected

    # Notify callbacks for a file given an array of callbacks
    #
    # @param [Pathname] path The file that was changed
    # @param [Symbol] callbacks_name The name of the callbacks method
    # @return [void]
    Contract Set, SourceFile => Any
    def run_callbacks(callbacks, descriptor)
      callbacks.each do |callback|
        callback.call(descriptor)
      end
    end

    # Work around this bug: http://bugs.ruby-lang.org/issues/4521
    # where Ruby will call to_s/inspect while printing exception
    # messages, which can take a long time (minutes at full CPU)
    # if the object is huge or has cyclic references, like this.
    def to_s
      "#<Middleman::SourceDirectory:0x#{object_id} type=#{@type.inspect} directory=#{@directory.inspect}>"
    end
    alias_method :inspect, :to_s # Ruby 2.0 calls inspect for NoMethodError instead of to_s
  end
end
