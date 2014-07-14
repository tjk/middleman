# For instrumenting
require 'active_support/notifications'

# Using Thor's indifferent hash access
require 'thor'

# Core Pathname library used for traversal
require 'pathname'

# Template and Mime detection
require 'tilt'
require 'rack/mime'

# DbC
require 'middleman-core/contracts'

# For URI templating
require 'addressable/template'
require 'active_support/inflector'
require 'active_support/inflector/transliterate'

module Middleman
  module Util
    include Contracts

    # A hash with indifferent access and magic predicates.
    # Copied from Thor
    #
    #   hash = Middleman::Util::HashWithIndifferentAccess.new 'foo' => 'bar', 'baz' => 'bee', 'force' => true
    #
    #   hash[:foo]  #=> 'bar'
    #   hash['foo'] #=> 'bar'
    #   hash.foo?   #=> true
    #
    class HashWithIndifferentAccess < ::Hash #:nodoc:
      def initialize(hash={})
        super()
        hash.each do |key, value|
          self[convert_key(key)] = value
        end
      end

      def [](key)
        super(convert_key(key))
      end

      def []=(key, value)
        super(convert_key(key), value)
      end

      def delete(key)
        super(convert_key(key))
      end

      def values_at(*indices)
        indices.map { |key| self[convert_key(key)] }
      end

      def merge(other)
        dup.merge!(other)
      end

      def merge!(other)
        other.each do |key, value|
          self[convert_key(key)] = value
        end
        self
      end

      # Convert to a Hash with String keys.
      def to_hash
        Hash.new(default).merge!(self)
      end

      protected

      def convert_key(key)
        key.is_a?(Symbol) ? key.to_s : key
      end

      # Magic predicates. For instance:
      #
      #   options.force?                  # => !!options['force']
      #   options.shebang                 # => "/usr/lib/local/ruby"
      #   options.test_framework?(:rspec) # => options[:test_framework] == :rspec
      # rubocop:disable DoubleNegation
      def method_missing(method, *args)
        method = method.to_s
        if method =~ /^(\w+)\?$/
          if args.empty?
            !!self[$1]
          else
            self[$1] == args.first
          end
        else
          self[method]
        end
      end
    end

    # Whether the source file is binary.
    #
    # @param [String] filename The file to check.
    # @return [Boolean]
    Contract String => Bool
    def self.binary?(filename)
      ext = File.extname(filename)

      # We hardcode detecting of gzipped SVG files
      return true if ext == '.svgz'

      return false if Tilt.registered?(ext.sub('.', ''))

      dot_ext = (ext.to_s[0] == '.') ? ext.dup : ".#{ext}"

      if mime = ::Rack::Mime.mime_type(dot_ext, nil)
        !nonbinary_mime?(mime)
      else
        file_contents_include_binary_bytes?(filename)
      end
    end

    # Takes a matcher, which can be a literal string
    # or a string containing glob expressions, or a
    # regexp, or a proc, or anything else that responds
    # to #match or #call, and returns whether or not the
    # given path matches that matcher.
    #
    # @param [String, #match, #call] matcher A matcher String, RegExp, Proc, etc.
    # @param [String] path A path as a string
    # @return [Boolean] Whether the path matches the matcher
    Contract PATH_MATCHER, String => Bool
    def self.path_match(matcher, path)
      case
      when matcher.is_a?(String)
        if matcher.include? '*'
          File.fnmatch(matcher, path)
        else
          path == matcher
        end
      when matcher.respond_to?(:match)
        !matcher.match(path).nil?
      when matcher.respond_to?(:call)
        matcher.call(path)
      else
        File.fnmatch(matcher.to_s, path)
      end
    end

    # Recursively convert a normal Hash into a HashWithIndifferentAccess
    #
    # @private
    # @param [Hash] data Normal hash
    # @return [Middleman::Util::HashWithIndifferentAccess]
    Contract Or[Hash, Array] => Or[HashWithIndifferentAccess, Array]
    def self.recursively_enhance(data)
      if data.is_a? Hash
        enhanced = ::Middleman::Util::HashWithIndifferentAccess.new(data)

        enhanced.each do |key, val|
          enhanced[key] = if val.is_a?(Hash) || val.is_a?(Array)
            recursively_enhance(val)
          else
            val
          end
        end

        enhanced
      elsif data.is_a? Array
        enhanced = data.dup

        enhanced.each_with_index do |val, i|
          enhanced[i] = if val.is_a?(Hash) || val.is_a?(Array)
            recursively_enhance(val)
          else
            val
          end
        end

        enhanced
      end
    end

    # Normalize a path to not include a leading slash
    # @param [String] path
    # @return [String]
    Contract String => String
    def self.normalize_path(path)
      # The tr call works around a bug in Ruby's Unicode handling
      path.sub(%r{^/}, '').tr('', '')
    end

    # This is a separate method from normalize_path in case we
    # change how we normalize paths
    Contract String => String
    def self.strip_leading_slash(path)
      path.sub(%r{^/}, '')
    end

    # Facade for ActiveSupport/Notification
    def self.instrument(name, payload={}, &block)
      suffixed_name = (name =~ /\.middleman$/) ? name.dup : "#{name}.middleman"
      ::ActiveSupport::Notifications.instrument(suffixed_name, payload, &block)
    end

    # Extract the text of a Rack response as a string.
    # Useful for extensions implemented as Rack middleware.
    # @param response The response from #call
    # @return [String] The whole response as a string.
    Contract RespondTo[:each] => String
    def self.extract_response_text(response)
      # The rack spec states all response bodies must respond to each
      result = ''
      response.each do |part, _|
        result << part
      end
      result
    end

    # Get a recusive list of files inside a path.
    # Works with symlinks.
    #
    # @param path Some path string or Pathname
    # @param ignore A proc/block that returns true if a given path should be ignored - if a path
    #               is ignored, nothing below it will be searched either.
    # @return [Array<Pathname>] An array of Pathnames for each file (no directories)
    Contract Or[String, Pathname], Proc => ArrayOf[Pathname]
    def self.all_files_under(path, &ignore)
      path = Pathname(path)

      if path.directory?
        path.children.flat_map do |child|
          all_files_under(child, &ignore)
        end.compact
      elsif path.file?
        if block_given? && ignore.call(path)
          []
        else
          [path]
        end
      else
        []
      end
    end

    # Get the path of a file of a given type
    #
    # @param [Middleman::Application] app The app.
    # @param [Symbol] kind The type of file
    # @param [String, Symbol] source The path to the file
    # @param [Hash] options Data to pass through.
    # @return [String]
    Contract IsA['Middleman::Application'], Symbol, Or[String, Symbol], Hash => String
    def self.asset_path(app, kind, source, options={})
      return source if source.to_s.include?('//') || source.to_s.start_with?('data:')

      asset_folder = case kind
      when :css
        app.config[:css_dir]
      when :js
        app.config[:js_dir]
      when :images
        app.config[:images_dir]
      when :fonts
        app.config[:fonts_dir]
      else
        kind.to_s
      end

      source = source.to_s.tr(' ', '')
      ignore_extension = (kind == :images || kind == :fonts) # don't append extension
      source << ".#{kind}" unless ignore_extension || source.end_with?(".#{kind}")
      asset_folder = '' if source.start_with?('/') # absolute path

      asset_url(app, source, asset_folder, options)
    end

    # Get the URL of an asset given a type/prefix
    #
    # @param [String] path The path (such as "photo.jpg")
    # @param [String] prefix The type prefix (such as "images")
    # @param [Hash] options Data to pass through.
    # @return [String] The fully qualified asset url
    Contract IsA['Middleman::Application'], String, String, Hash => String
    def self.asset_url(app, path, prefix='', _options={})
      # Don't touch assets which already have a full path
      if path.include?('//') || path.start_with?('data:')
        path
      else # rewrite paths to use their destination path
        if resource = app.sitemap.find_resource_by_destination_path(url_for(app, path))
          resource.url
        else
          path = File.join(prefix, path)
          if resource = app.sitemap.find_resource_by_path(path)
            resource.url
          else
            File.join(app.config[:http_prefix], path)
          end
        end
      end
    end

    # Given a source path (referenced either absolutely or relatively)
    # or a Resource, this will produce the nice URL configured for that
    # path, respecting :relative_links, directory indexes, etc.
    Contract IsA['Middleman::Application'], Or[String, IsA['Middleman::Sitemap::Resource']], Hash => String
    def self.url_for(app, path_or_resource, options={})
      # Handle Resources and other things which define their own url method
      url = if path_or_resource.respond_to?(:url)
        path_or_resource.url
      else
        path_or_resource.dup
      end.gsub(' ', '%20')

      # Try to parse URL
      begin
        uri = URI(url)
      rescue URI::InvalidURIError
        # Nothing we can do with it, it's not really a URI
        return url
      end

      relative = options[:relative]
      raise "Can't use the relative option with an external URL" if relative && uri.host

      # Allow people to turn on relative paths for all links with
      # set :relative_links, true
      # but still override on a case by case basis with the :relative parameter.
      effective_relative = relative || false
      effective_relative = true if relative.nil? && app.config[:relative_links]

      # Try to find a sitemap resource corresponding to the desired path
      this_resource = options[:current_resource]

      if path_or_resource.is_a?(::Middleman::Sitemap::Resource)
        resource = path_or_resource
        resource_url = url
      elsif this_resource && uri.path
        # Handle relative urls
        url_path = Pathname(uri.path)
        current_source_dir = Pathname('/' + this_resource.path).dirname
        url_path = current_source_dir.join(url_path) if url_path.relative?
        resource = app.sitemap.find_resource_by_path(url_path.to_s)
        resource_url = resource.url if resource
      elsif options[:find_resource] && uri.path
        resource = app.sitemap.find_resource_by_path(uri.path)
        resource_url = resource.url if resource
      end

      if resource
        uri.path = if this_resource
          relative_path_from_resource(this_resource, resource_url, effective_relative)
        else
          resource_url
        end
      else
        # If they explicitly asked for relative links but we can't find a resource...
        raise "No resource exists at #{url}" if relative
      end

      # Support a :query option that can be a string or hash
      if query = options[:query]
        uri.query = query.respond_to?(:to_param) ? query.to_param : query.to_s
      end

      # Support a :fragment or :anchor option just like Padrino
      fragment = options[:anchor] || options[:fragment]
      uri.fragment = fragment.to_s if fragment

      # Finally make the URL back into a string
      uri.to_s
    end

    # Expand a path to include the index file if it's a directory
    #
    # @param [String] path Request path/
    # @param [Middleman::Application] app The requesting app.
    # @return [String] Path with index file if necessary.
    Contract String, IsA['Middleman::Application'] => String
    def self.full_path(path, app)
      resource = app.sitemap.find_resource_by_destination_path(path)

      unless resource
        # Try it with /index.html at the end
        indexed_path = File.join(path.sub(%r{/$}, ''), app.config[:index_file])
        resource = app.sitemap.find_resource_by_destination_path(indexed_path)
      end

      if resource
        '/' + resource.destination_path
      else
        '/' + normalize_path(path)
      end
    end

    Contract String, String, ArrayOf[String], Proc => String
    def self.rewrite_paths(body, _path, exts, &_block)
      body.dup.gsub(/([=\'\"\(]\s*)([^\s\'\"\)]+(#{Regexp.union(exts)}))/) do |match|
        opening_character = $1
        asset_path = $2

        if result = yield(asset_path)
          "#{opening_character}#{result}"
        else
          match
        end
      end
    end

    # Is mime type known to be non-binary?
    #
    # @param [String] mime The mimetype to check.
    # @return [Boolean]
    Contract String => Bool
    def self.nonbinary_mime?(mime)
      case
      when mime.start_with?('text/')
        true
      when mime.include?('xml')
        true
      when mime.include?('json')
        true
      when mime.include?('javascript')
        true
      else
        false
      end
    end

    # Read a few bytes from the file and see if they are binary.
    #
    # @param [String] filename The file to check.
    # @return [Boolean]
    Contract String => Bool
    def self.file_contents_include_binary_bytes?(filename)
      binary_bytes = [0, 1, 2, 3, 4, 5, 6, 11, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 28, 29, 30, 31]
      s = File.read(filename, 4096) || ''
      s.each_byte do |c|
        return true if binary_bytes.include?(c)
      end

      false
    end

    # Get a relative path to a resource.
    #
    # @param [Middleman::Sitemap::Resource] curr_resource The resource.
    # @param [String] resource_url The target url.
    # @param [Boolean] relative If the path should be relative.
    # @return [String]
    Contract IsA['Middleman::Sitemap::Resource'], String, Bool => String
    def self.relative_path_from_resource(curr_resource, resource_url, relative)
      # Switch to the relative path between resource and the given resource
      # if we've been asked to.
      if relative
        # Output urls relative to the destination path, not the source path
        current_dir = Pathname('/' + curr_resource.destination_path).dirname
        relative_path = Pathname(resource_url).relative_path_from(current_dir).to_s

        # Put back the trailing slash to avoid unnecessary Apache redirects
        if resource_url.end_with?('/') && !relative_path.end_with?('/')
          relative_path << '/'
        end

        relative_path
      else
        resource_url
      end
    end
    
    # Handy methods for dealing with URI templates. Mix into whatever class.
    module UriTemplates

      module_function

      # Given a URI template string, make an Addressable::Template
      # This supports the legacy middleman-blog/Sinatra style :colon
      # URI templates as well as RFC6570 templates.
      #
      # @param [String] tmpl_src URI template source
      # @return [Addressable::Template] a URI template
      def uri_template(tmpl_src)
        # Support the RFC6470 templates directly if people use them
        if tmpl_src.include?(':')
          tmpl_src = tmpl_src.gsub(/:([A-Za-z0-9]+)/, '{\1}')
        end

        Addressable::Template.new ::Middleman::Util.normalize_path(tmpl_src)
      end

      # Apply a URI template with the given data, producing a normalized
      # Middleman path.
      #
      # @param [Addressable::Template] template
      # @param [Hash] data
      # @return [String] normalized path
      def apply_uri_template(template, data)
        ::Middleman::Util.normalize_path Addressable::URI.unencode(template.expand(data)).to_s
      end

      # Use a template to extract parameters from a path, and validate some special (date)
      # keys. Returns nil if the special keys don't match.
      #
      # @param [Addressable::Template] template
      # @param [String] path
      def extract_params(template, path)
        params = template.extract(path, BlogTemplateProcessor)
      end

      # Parameterize a string preserving any multibyte characters
      def safe_parameterize(str)
        sep = '-'

        # Reimplementation of http://api.rubyonrails.org/classes/ActiveSupport/Inflector.html#method-i-parameterize that preserves un-transliterate-able multibyte chars.
        parameterized_string = ActiveSupport::Inflector.transliterate(str.to_s).downcase
        parameterized_string.gsub!(/[^a-z0-9\-_\?]+/, sep)

        parameterized_string.chars.to_a.each_with_index do |char, i|
          if char == '?' && str[i].bytes.count != 1
            parameterized_string[i] = str[i]
          end
        end

        re_sep = Regexp.escape(sep)
        # No more than one of the separator in a row.
        parameterized_string.gsub!(/#{re_sep}{2,}/, sep)
        # Remove leading/trailing separator.
        parameterized_string.gsub!(/^#{re_sep}|#{re_sep}$/, '')

        parameterized_string
      end

      # Convert a date into a hash of components to strings
      # suitable for using in a URL template.
      # @param [DateTime] date
      # @return [Hash] parameters
      def date_to_params(date)
        return {
          year: date.year.to_s,
          month: date.month.to_s.rjust(2,'0'),
          day: date.day.to_s.rjust(2,'0')
        }
      end
    end

    # A special template processor that validates date fields
    # and has an extra-permissive default regex.
    #
    # See https://github.com/sporkmonger/addressable/blob/master/lib/addressable/template.rb#L279
    class BlogTemplateProcessor
      def self.match(name)
        case name
        when 'year' then '\d{4}'
        when 'month' then '\d{2}'
        when 'day' then '\d{2}'
        else '.*?'
        end
      end
    end
  end
end
