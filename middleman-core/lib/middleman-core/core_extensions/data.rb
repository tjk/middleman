require 'yaml'
require 'active_support/json'
require 'middleman-core/contracts'

module Middleman
  module CoreExtensions
    # The data extension parses YAML and JSON files in the `data/` directory
    # and makes them available to `config.rb`, templates and extensions
    class Data < Extension
      attr_reader :data_store

      def initialize(app, config={}, &block)
        super

        # The regex which tells Middleman which files are for data
        data_file_matcher = /^(.*?)[\w-]+\.(yml|yaml|json)$/

        @data_store = DataStore.new(app, data_file_matcher)
        app.config.define_setting :data_dir, 'data', 'The directory data files are stored in'

        app.add_to_config_context(:data, &method(:data_store))

        start_watching(app.config[:data_dir])
      end

      def start_watching(dir)
        @original_data_dir = dir

        # Tell the file watcher to observe the :data_dir
        @watcher = app.files.watch :data,
                                   File.join(app.root, dir),
                                   ignore: proc { |f| !data_file_matcher.match(f[:relative_path]) }

        # Setup data files before anything else so they are available when
        # parsing config.rb
        @watcher.changed(&@data_store.method(:touch_file))
        @watcher.deleted(&@data_store.method(:remove_file))
      end

      def after_configuration
        return unless @original_data_dir != app.config[:data_dir]

        @watcher.update_path(app.config[:data_dir])
      end

      helpers do
        def data
          extensions[:data].data_store
        end
      end

      # The core logic behind the data extension.
      class DataStore
        include Contracts

        # Setup data store
        #
        # @param [Middleman::Application] app The current instance of Middleman
        def initialize(app, data_file_matcher)
          @app = app
          @data_file_matcher = data_file_matcher
          @local_data = {}
          @local_sources = {}
          @callback_sources = {}
        end

        # Store static data hash
        #
        # @param [Symbol] name Name of the data, used for namespacing
        # @param [Hash] content The content for this data
        # @return [Hash]
        Contract Symbol, Hash => Hash
        def store(name=nil, content=nil)
          @local_sources[name.to_s] = content unless name.nil? || content.nil?
          @local_sources
        end

        # Store callback-based data
        #
        # @param [Symbol] name Name of the data, used for namespacing
        # @param [Proc] proc The callback which will return data
        # @return [Hash]
        Contract Symbol, Proc => Hash
        def callbacks(name=nil, proc=nil)
          @callback_sources[name.to_s] = proc unless name.nil? || proc.nil?
          @callback_sources
        end

        # Update the internal cache for a given file path
        #
        # @param [String] file The file to be re-parsed
        # @return [void]
        Contract IsA['Middleman::SourceFile'] => Any
        def touch_file(file)
          data_path = file[:relative_path]
          extension = File.extname(data_path)
          basename  = File.basename(data_path, extension)

          if %w(.yaml .yml).include?(extension)
            data = YAML.load_file(file[:full_path])
          elsif extension == '.json'
            data = ActiveSupport::JSON.decode(file[:full_path].read)
          else
            return
          end

          data_branch = @local_data

          path = data_path.to_s.split(File::SEPARATOR)[0..-2]
          path.each do |dir|
            data_branch[dir] ||= {}
            data_branch = data_branch[dir]
          end

          data_branch[basename] = data
        end

        # Remove a given file from the internal cache
        #
        # @param [String] file The file to be cleared
        # @return [void]
        Contract IsA['Middleman::SourceFile'] => Any
        def remove_file(file)
          data_path = file[:relative_path]
          extension = File.extname(data_path)
          basename  = File.basename(data_path, extension)

          data_branch = @local_data

          path = data_path.to_s.split(File::SEPARATOR)[0..-2]
          path.each do |dir|
            data_branch = data_branch[dir]
          end

          data_branch.delete(basename) if data_branch.key?(basename)
        end

        # Get a hash from either internal static data or a callback
        #
        # @param [String, Symbol] path The name of the data namespace
        # @return [Hash, nil]
        Contract Or[String, Symbol] => Maybe[Hash]
        def data_for_path(path)
          response = if store.key?(path.to_s)
            store[path.to_s]
          elsif callbacks.key?(path.to_s)
            callbacks[path.to_s].call
          end

          response = ::Middleman::Util.recursively_enhance(response)
          response
        end

        # "Magically" find namespaces of data if they exist
        #
        # @param [String] path The namespace to search for
        # @return [Hash, nil]
        def method_missing(path)
          if @local_data.key?(path.to_s)
            @local_data[path.to_s] = ::Middleman::Util.recursively_enhance(@local_data[path.to_s])
            return @local_data[path.to_s]
          else
            result = data_for_path(path)
            return result if result
          end

          super
        end

        # Needed so that method_missing makes sense
        def respond_to?(method, include_private=false)
          super || key?(method)
        end

        # Make DataStore act like a hash. Return requested data, or
        # nil if data does not exist
        #
        # @param [String, Symbol] key The name of the data namespace
        # @return [Hash, nil]
        def [](key)
          __send__(key) if key?(key)
        end

        def key?(key)
          @local_data.key?(key.to_s) || data_for_path(key)
        end

        alias_method :has_key?, :key?

        # Convert all the data into a static hash
        #
        # @return [Hash]
        Contract None => Hash
        def to_h
          data = {}

          store.each do |k, _|
            data[k] = data_for_path(k)
          end

          callbacks.each do |k, _|
            data[k] = data_for_path(k)
          end

          (@local_data || {}).each do |k, v|
            data[k] = v
          end

          data
        end
      end
    end
  end
end
