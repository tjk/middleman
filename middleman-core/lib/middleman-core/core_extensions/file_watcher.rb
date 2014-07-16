require 'pathname'
require 'set'
require 'middleman-core/contracts'
require 'middleman-core/sources'

module Middleman
  module CoreExtensions
    # API for watching file change events
    class FileWatcher < Extension
      attr_reader :sources

      IGNORES = {
        emacs_files: /(^|\/)\.?#/,
        tilde_files: /~$/,
        ds_store: /\.DS_Store$/,
        git: /(^|\/)\.git(ignore|modules|\/)/
      }

      def initialize(app, config={}, &block)
        super

        @sources = ::Middleman::Sources.new(app,
                                            disable_watcher: app.config[:watcher_disable],
                                            force_polling: app.config[:force_polling],
                                            latency: app.config[:watcher_latency])

        IGNORES.each do |key, value|
          @sources.ignore key, :all, value
        end

        start_watching(app.config[:source])

        app.add_to_instance(:files, &method(:sources))
        app.add_to_config_context(:files, &method(:sources))
      end

      def start_watching(dir)
        @original_source_dir = dir
        @watcher = @sources.watch :source, File.join(app.root, dir)
      end

      def before_configuration
        @sources.find_new_files!
      end

      def after_configuration
        if @original_source_dir != app.config[:source]
          @watcher.update_path(app.config[:source])
        end

        @sources.start!
        @sources.find_new_files!
      end
    end
  end
end
