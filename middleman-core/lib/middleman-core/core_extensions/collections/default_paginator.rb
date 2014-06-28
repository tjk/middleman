require 'middleman-core/core_extensions/collections/paginator'

module Middleman
  module CoreExtensions
    module Collections
      class DefaultPaginator < Paginator
        def initialize(app, collection, opts={}, block)
          super
        end

        Contract ResourceList => ResourceList
        def manipulate_resource_list(resources)
          paging_proxies = []
          prev_page_res = nil
          num_pages = (@collection.length / @options[:per_page].to_f).ceil

          sort_proc = @options[:sort] || proc { |a, b| a.destination_path <=> b.destination_path }

          @collection.sort(&sort_proc).each_slice(@options[:per_page]).each_with_index do |items, i|
            path = i == 0 ? "/2011/index.html" : "/2011/page/#{i+1}.html";
            target = "/archive/2011/index.html"

            # Allow blog.per_page and blog.page_link to be overridden in the frontmatter
            # page_link = ::Middleman::Util::UriTemplates.uri_template(
            #     md[:page]["page_link"] || @options[:page_link])

            p = ::Middleman::Sitemap::ProxyResource.new(@app.sitemap, ::Middleman::Util.normalize_path(path), ::Middleman::Util.normalize_path(target))
            p.add_metadata({ page: { pagination: { items: items } } })

            if i == 0
              # Add the pagination metadata to the base page (page 1)
              p.add_metadata page: page_locals(1, num_pages, @options[:per_page], nil)

              prev_page_res = p
            else
              # Copy the metadata from the base page
              # p.add_metadata md
              p.add_metadata page: page_locals(i+1, num_pages, @options[:per_page], prev_page_res)

              # Add a reference in the previous page to this page
              prev_page_res.add_metadata page: { pagination: { next_page: p } }
            end

            prev_page_res = p
            paging_proxies << p
          end

          super + paging_proxies
        end

        # @param [Integer] page_num the page number to generate a resource for
        # @param [Integer] num_pages Total number of pages
        # @param [Integer] per_page How many items per page
        # @param [Sitemap::Resource] prev_page_res The resource of the previous page
        def page_locals(page_num, num_pages, per_page, prev_page_res)
          # Index into collection of the first item of this page
          page_start = (page_num - 1) * per_page

          # Index into collection of the last item of this page
          page_end = (page_num * per_page) - 1

          {
            pagination: {
              # Include the numbers, useful for displaying "Page X of Y"
              page_number: page_num,
              num_pages: num_pages,
              per_page: per_page,

              # The range of item numbers on this page
              # (1-based, for showing "Items X to Y of Z")
              page_start: page_start + 1,
              page_end: [page_end + 1, @collection.length].min,

              # These contain the next and previous page.
              # They are set to nil if there are no more pages.
              # The nils are overwritten when the later pages are generated, below.
              next_page: nil,
              prev_page: prev_page_res,

              # Use "collection" in templates.
              collection: @collection
            }
          }
        end
      end
    end
  end
end
