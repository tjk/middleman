require 'rack/showexceptions'

# Support rack/showexceptions during development
module Middleman::CoreExtensions
  class ShowExceptions < ::Middleman::Extension
    def initialize(app, options_hash={}, &block)
      super

      app.config.define_setting :show_exceptions, !!ENV['TEST'], 'Whether to catch and display exceptions'
    end

    def after_configuration
      app.use ::Rack::ShowExceptions if !app.build? && app.config[:show_exceptions]
    end
  end
end
