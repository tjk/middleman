require 'tilt'
require 'active_support/core_ext/string/output_safety'
require 'active_support/core_ext/module/delegation'
require 'middleman-core/contracts'

::Tilt.mappings.delete('html') # WTF, Tilt?
::Tilt.mappings.delete('csv')

module Middleman
  class FileRenderer
    extend Forwardable
    include Contracts

    def self.cache
      @_cache ||= ::Tilt::Cache.new
    end

    def_delegator :"self.class", :cache

    def initialize(app, path)
      @app = app
      @path = path.to_s
    end

    # Render an on-disk file. Used for everything, including layouts.
    #
    # @param [Hash] locs
    # @param [Hash] opts
    # @param [Class] context
    # @return [String]
    Contract Hash, Hash, Any, Proc => String
    def render(locs={}, opts={}, context, &block)
      path = @path.dup

      # Detect the remdering engine from the extension
      extension = File.extname(path)
      engine = extension[1..-1].to_sym

      # Store last engine for later (could be inside nested renders)
      context.current_engine, engine_was = engine, context.current_engine

      # Save current buffer for later
      buf_was = context.save_buffer

      # Read from disk or cache the contents of the file
      body = if opts[:template_body]
        opts.delete(:template_body)
      else
        template_data_for_file
      end

      # Merge per-extension options from config
      extension = File.extname(path)
      options = opts.merge(options_for_ext(extension))
      options[:outvar] ||= '@_out_buf'
      options.delete(:layout)

      # Overwrite with frontmatter options
      options = options.deep_merge(options[:renderer_options]) if options[:renderer_options]

      template_class = ::Tilt[path]
      # Allow hooks to manipulate the template before render
      @app.class.callbacks_for_hook(:before_render).each do |callback|
        newbody = if callback.respond_to?(:call)
          callback.call(body, path, locs, template_class)
        elsif callback.respond_to?(:evaluate)
          callback.evaluate(self, body, path, locs, template_class)
        end
        body = newbody if newbody # Allow the callback to return nil to skip it
      end

      # Read compiled template from disk or cache
      template = cache.fetch(:compiled_template, extension, options, body) do
        ::Tilt.new(path, 1, options) { body }
      end

      # Render using Tilt
      content = template.render(context, locs, &block)

      # Allow hooks to manipulate the result after render
      @app.class.callbacks_for_hook(:after_render).each do |callback|
        # Uber::Options::Value doesn't respond to call
        newcontent = if callback.respond_to?(:call)
          callback.call(content, path, locs, template_class)
        elsif callback.respond_to?(:evaluate)
          callback.evaluate(self, content, path, locs, template_class)
        end
        content = newcontent if newcontent # Allow the callback to return nil to skip it
      end

      output = ::ActiveSupport::SafeBuffer.new ''
      output.safe_concat content
      output
    ensure
      # Reset stored buffer
      context.restore_buffer(buf_was)
      context.current_engine = engine_was
    end

    # Get the template data from a path
    # @param [String] path
    # @return [String]
    Contract None => String
    def template_data_for_file
      if @app.extensions[:front_matter]
        @app.extensions[:front_matter].template_data_for_file(@path) || ''
      else
        File.read(File.expand_path(@path, @app.source_dir))
      end
    end

    protected

    # Get a hash of configuration options for a given file extension, from
    # config.rb
    #
    # @param [String] ext
    # @return [Hash]
    Contract String => Hash
    def options_for_ext(ext)
      # Read options for extension from config/Tilt or cache
      cache.fetch(:options_for_ext, ext) do
        options = {}

        # Find all the engines which handle this extension in tilt. Look for
        # config variables of that name and merge it
        extension_class = ::Tilt[ext]
        ::Tilt.mappings.each do |mapping_ext, engines|
          next unless engines.include? extension_class
          engine_options = @app.config[mapping_ext.to_sym] || {}
          options.merge!(engine_options)
        end

        options
      end
    end
  end
end
