module Middleman
  module CoreExtensions
    module Collections
      class Paginator
        include Contracts

        Contract IsA['Middleman::Application'], IsA['Middleman::CoreExtensions::Collections::Collection'], Hash, Maybe[Proc] => Any
        def initialize(app, collection, opts={}, block)
          @app = app
          @collection = collection
          @options = opts
          @block = block
        end

          # matched.each_slice(@options[:per_page]).each_with_index do |items, i|
          #   instance_exec(items, i + 1, &@block)
          # end

        Contract ResourceList => ResourceList
        def manipulate_resource_list(resources)
          resources
        end
      end
    end
  end
end
