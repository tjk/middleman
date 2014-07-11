class Middleman::Extensions::ExternalPipeline < ::Middleman::Extension
  self.supports_multiple_instances = true

  option :name, nil, 'The name of the pipeline'
  option :command, nil, 'The command to initialize'
  option :source, nil, 'Path to merge into sitemap'

  def initialize(app, config={}, &block)
    super

    if options[:name].nil?
      throw "Name is required"
    end

    if options[:command].nil?
      throw "Command is required"
    end

    if options[:source].nil?
      throw "Source is required"
    end

    require 'thread'

    app.files.watch options[:name], /^#{options[:source]}\/(.*?)[\w-]+\.(.*?)$/
  end

  def after_configuration
    if app.build?
      logger.info "== Executing: `#{options[:command]}`"
      watch_command!
    else
      logger.debug "== Executing: `#{options[:command]}`"
      ::Thread.new { watch_command! }
    end
  end

  def watch_command!
    ::IO.popen(options[:command], 'r') do |pipe|
      while buf = pipe.gets
        without_newline = buf.sub(/\n$/,'')
        logger.info "== External: #{without_newline}" if without_newline.length > 0
      end
    end
  end

  # Update the main sitemap resource list
  # @return Array<Middleman::Sitemap::Resource>
  Contract ResourceList => ResourceList
  def manipulate_resource_list(resources)
    files = ::Middleman::Util.all_files_under(options[:source])
    resources + files.map do |file|
      ::Middleman::Sitemap::Resource.new(
        @app.sitemap,
        @app.sitemap.file_to_path(file, File.expand_path(options[:source])),
        File.join(@app.root, file)
      )
    end
  end
end
