require 'rack/mime'
require 'middleman-core/sitemap/extensions/traversal'
require 'middleman-core/file_renderer'
require 'middleman-core/template_renderer'
require 'middleman-core/contracts'

module Middleman
  # Sitemap namespace
  module Sitemap
    # Sitemap Resource class
    class Resource
      include Contracts
      include Middleman::Sitemap::Extensions::Traversal

      # The source path of this resource (relative to the source directory,
      # without template extensions)
      # @return [String]
      attr_reader :path

      # The output path in the build directory for this resource
      # @return [String]
      attr_accessor :destination_path

      # The on-disk source file for this resource, if there is one
      # @return [String]
      attr_reader :source_file

      # The path to use when requesting this resource. Normally it's
      # the same as {#destination_path} but it can be overridden in subclasses.
      # @return [String]
      alias_method :request_path, :destination_path

      METADATA_HASH = ({ options: Maybe[Hash], locals: Maybe[Hash], page: Maybe[Hash] })

      # The metadata for this resource
      # @return [Hash]
      Contract None => METADATA_HASH
      attr_reader :metadata

      # Initialize resource with parent store and URL
      # @param [Middleman::Sitemap::Store] store
      # @param [String] path
      # @param [String] source_file
      def initialize(store, path, source_file=nil)
        @store       = store
        @app         = @store.app
        @path        = path.gsub(' ', '%20') # handle spaces in filenames
        @source_file = source_file
        @destination_path = @path

        # Options are generally rendering/sitemap options
        # Locals are local variables for rendering this resource's template
        # Page are data that is exposed through this resource's data member.
        # Note: It is named 'page' for backwards compatibility with older MM.
        @metadata = { options: {}, locals: {}, page: {} }
      end

      # Whether this resource has a template file
      # @return [Boolean]
      Contract None => Bool
      def template?
        return false if source_file.nil?
        !::Tilt[source_file].nil?
      end

      # Merge in new metadata specific to this resource.
      # @param [Hash] meta A metadata block with keys :options, :locals, :page.
      #   Options are generally rendering/sitemap options
      #   Locals are local variables for rendering this resource's template
      #   Page are data that is exposed through this resource's data member.
      #   Note: It is named 'page' for backwards compatibility with older MM.
      Contract METADATA_HASH => METADATA_HASH
      def add_metadata(meta={})
        @metadata.deep_merge!(meta)
      end

      # Data about this resource, populated from frontmatter or extensions.
      # @return [HashWithIndifferentAccess]
      Contract None => IsA['Middleman::Util::HashWithIndifferentAccess']
      def data
        # TODO: Should this really be a HashWithIndifferentAccess?
        ::Middleman::Util.recursively_enhance(metadata[:page]).freeze
      end

      # Options about how this resource is rendered, such as its :layout,
      # :renderer_options, and whether or not to use :directory_indexes.
      # @return [Hash]
      Contract None => Hash
      def options
        metadata[:options]
      end

      # Local variable mappings that are used when rendering the template for this resource.
      # @return [Hash]
      Contract None => Hash
      def locals
        metadata[:locals]
      end

      # Extension of the path (i.e. '.js')
      # @return [String]
      Contract None => String
      def ext
        File.extname(path)
      end

      # Render this resource
      # @return [String]
      Contract Hash, Hash => String
      def render(opts={}, locs={})
        return ::Middleman::FileRenderer.new(@app, source_file).template_data_for_file unless template?

        relative_source = Pathname(source_file).relative_path_from(Pathname(@app.root))

        ::Middleman::Util.instrument 'render.resource', path: relative_source, destination_path: destination_path do
          md   = metadata
          opts = md[:options].deep_merge(opts)
          locs = md[:locals].deep_merge(locs)
          locs[:current_path] ||= destination_path

          # Certain output file types don't use layouts
          unless opts.key?(:layout)
            opts[:layout] = false if %w(.js .json .css .txt).include?(ext)
          end

          renderer = ::Middleman::TemplateRenderer.new(@app, source_file)
          renderer.render(locs, opts)
        end
      end

      # A path without the directory index - so foo/index.html becomes
      # just foo. Best for linking.
      # @return [String]
      Contract None => String
      def url
        url_path = destination_path
        if @app.config[:strip_index_file]
          url_path = url_path.sub(/(^|\/)#{Regexp.escape(@app.config[:index_file])}$/,
                                  @app.config[:trailing_slash] ? '/' : '')
        end
        File.join(@app.config[:http_prefix], url_path)
      end

      # Whether the source file is binary.
      #
      # @return [Boolean]
      Contract None => Bool
      def binary?
        !source_file.nil? && ::Middleman::Util.binary?(source_file)
      end

      # Ignore a resource directly, without going through the whole
      # ignore filter stuff.
      # @return [void]
      Contract None => Any
      def ignore!
        @ignored = true
      end

      # Whether the Resource is ignored
      # @return [Boolean]
      Contract None => Bool
      def ignored?
        return true if @ignored
        # Ignore based on the source path (without template extensions)
        return true if @app.sitemap.ignored?(path)
        # This allows files to be ignored by their source file name (with template extensions)
        !self.is_a?(ProxyResource) && @app.sitemap.ignored?(source_file.sub("#{@app.source_dir}/", ''))
      end

      # The preferred MIME content type for this resource based on extension or metadata
      # @return [String] MIME type for this resource
      Contract None => Maybe[String]
      def content_type
        options[:content_type] || ::Rack::Mime.mime_type(ext, nil)
      end

      def to_s
        "#<Middleman::Sitemap::Resource path=#{@path}>"
      end
      alias_method :inspect, :to_s # Ruby 2.0 calls inspect for NoMethodError instead of to_s
    end
  end
end
