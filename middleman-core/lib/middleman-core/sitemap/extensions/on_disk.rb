require 'set'
require 'middleman-core/contracts'

module Middleman
  module Sitemap
    module Extensions
      class OnDisk < Extension
        attr_accessor :waiting_for_ready

        def initialize(app, config={}, &block)
          super

          @file_paths_on_disk = Set.new

          scoped_self = self
          @waiting_for_ready = true

          @app.ready do
            scoped_self.waiting_for_ready = false
            # Make sure the sitemap is ready for the first request
            sitemap.ensure_resource_list_updated!
          end
        end

        Contract None => Any
        def before_configuration
          app.files.changed(&method(:touch_file))
          app.files.deleted(&method(:remove_file))
        end

        def ignored?(file)
          @app.config[:ignored_sitemap_matchers].any? do |_, callback|
            callback.call(file, @app)
          end
        end

        # Update or add an on-disk file path
        # @param [String] file
        # @return [void]
        Contract IsA['Middleman::SourceFile'] => Any
        def touch_file(file)
          return if ignored?(file)

          # Rebuild the sitemap any time a file is touched
          # in case one of the other manipulators
          # (like asset_hash) cares about the contents of this file,
          # whether or not it belongs in the sitemap (like a partial)
          @app.sitemap.rebuild_resource_list!(:touched_file)

          # Force sitemap rebuild so the next request is ready to go.
          # Skip this during build because the builder will control sitemap refresh.
          @app.sitemap.ensure_resource_list_updated! unless waiting_for_ready || @app.build?
        end

        # Remove a file from the store
        # @param [String] file
        # @return [void]
        Contract IsA['Middleman::SourceFile'] => Any
        def remove_file(file)
          return if ignored?(file)

          @app.sitemap.rebuild_resource_list!(:removed_file)

          # Force sitemap rebuild so the next request is ready to go.
          # Skip this during build because the builder will control sitemap refresh.
          @app.sitemap.ensure_resource_list_updated! unless waiting_for_ready || @app.build?
        end

        def files_for_sitemap
          @app.files.by_type(:source).files.reject(&method(:ignored?))
        end

        # Update the main sitemap resource list
        # @return Array<Middleman::Sitemap::Resource>
        Contract ResourceList => ResourceList
        def manipulate_resource_list(resources)
          resources + files_for_sitemap.map do |file|
            relative_path = file[:relative_path].to_s

            # Replace a file name containing automatic_directory_matcher with a folder
            unless @app.config[:automatic_directory_matcher].nil?
              relative_path = relative_path.gsub(@app.config[:automatic_directory_matcher], '/')
            end

            ::Middleman::Sitemap::Resource.new(
              @app.sitemap,
              @app.sitemap.extensionless_path(relative_path),
              file[:full_path].to_s
            )
          end
        end
      end
    end
  end
end
