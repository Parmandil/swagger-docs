require 'swagger/docs/slash_trimmer'

module Swagger
  module Docs
    class Generator
      DEFAULT_VER = "1.0"
      DEFAULT_CONFIG = {
        api_file_path:   "public/",
        api_file_name:   "api-docs.json",
        base_path:       "/",
        clean_directory: false,
        formatting:      :pretty
      }

      class << self

        def set_real_methods
          Config.base_api_controller.send(:include, Methods) # replace impotent methods with live ones
        end

        def write_docs(apis = nil)
          results = generate_docs(apis)
          results.each_value {|result| write_doc(result) }
          results
        end

        def write_doc(result)
          settings = result[:settings]
          config = result[:config]
          create_output_paths(settings[:api_file_path])

          if config[:clean_directory] || false
            clean_output_paths(settings[:api_file_path])
          end

          root = result[:root]
          resources = root.delete 'resources'
          root.merge!(config[:attributes] || {}) # merge custom user attributes like info
          # write the api-docs file
          full_api_file_path =
            File.join(settings[:api_file_path], config[:api_file_name])
          write_to_file(full_api_file_path, root, config)
          # write the individual resource files
          resources.each do |resource|
            resource_file_path = resource.delete 'resourceFilePath'
            resource_file_path =
              File.join(settings[:api_file_path], "#{resource_file_path}.json")

            write_to_file(resource_file_path, resource, config)
          end
          result
        end

        def generate_docs(apis=nil)
          apis ||= Config.registered_apis
          results = {}
          set_real_methods

          apis[DEFAULT_VER] = DEFAULT_CONFIG if apis.empty?

          apis.each do |api_version, config|
            settings = get_settings(api_version, config)
            config.reverse_merge!(DEFAULT_CONFIG)
            results[api_version] = generate_doc(api_version, settings, config)
            results[api_version][:settings] = settings
            results[api_version][:config] = config
          end
          results
        end

        def generate_doc(api_version, settings, config)
          root = {
            "apiVersion" => api_version,
            "swaggerVersion" => "1.2",
            "basePath" => settings[:base_path] + "/",
            apis: [],
            authorizations: settings[:authorizations]
          }
          results = {processed: [], skipped: []}
          resources = []

          get_route_paths(settings[:controller_base_path]).each do |path|
            ret = process_path(path, root, config, settings)
            results[ret[:action]] << ret

            if ret[:action] == :processed
              resources << generate_resource(
                ret[:path],
                ret[:apis],
                ret[:models],
                settings,
                root,
                config
              )

              debased_path = get_debased_path(
                ret[:path],
                settings[:controller_base_path]
              )

              path = SlashTrimmer.trim_leading_slashes(debased_path)
              path = Config.transform_path(path, api_version) + '.{format}'

              resource_api = {
                path: path,
                description: ret[:klass].swagger_config[:description]
              }
              root[:apis] << resource_api
            end
          end
          root['resources'] = resources
          results[:root] = root
          results
        end

        private

        def transform_spec_to_api_path(spec, controller_base_path, extension)
          api_path = spec.to_s.dup
          api_path.gsub!('(.:format)', extension ? ".#{extension}" : '')
          api_path.gsub!(/:(\w+)/, '{\1}')
          api_path.gsub!(controller_base_path, '')
          SlashTrimmer.trim_slashes(api_path)
        end

        def get_debased_path(path, controller_base_path)
          path.gsub("#{controller_base_path}", "")
        end

        def process_path(path, root, config, settings)
          return {action: :skipped, reason: :empty_path} if path.empty?
          controller_name = "#{path.to_s.camelize}Controller"
          klass = Config.log_exception { controller_name.constantize } rescue nil

          if !klass
            return {action: :skipped, path: path, reason: :klass_not_present}
          end

          if !klass.methods.include?(:swagger_config) ||
              !klass.swagger_config[:controller]
            return {action: :skipped, path: path, reason: :not_swagger_resource}
          end

          apis              = []
          models            = {}
          defined_nicknames = []

          routes.select{|i| i.defaults[:controller] == path}.each do |route|
            unless nickname_defined?(defined_nicknames, path, route) # only add once for each route e.g. PATCH, PUT
              ret  = get_route_path_apis(path, route, klass, settings, config)
              apis = apis + ret[:apis]
              models.merge!(ret[:models])

              if ret[:nickname].present?
                defined_nicknames << ret[:nickname]
              end
            end
          end

          {
            action: :processed,
            path:   path,
            apis:   apis,
            models: models,
            klass:  klass
          }
        end

        def route_verb(route)
          if defined?(route.verb.source)
            route.verb.source.to_s.delete('$'+'^')
          else
            route.verb
          end.downcase.to_sym
        end

        def path_route_nickname(path, route)
          action = route.defaults[:action]
          "#{path.camelize}##{action}"
        end

        def nickname_defined?(defined_nicknames, path, route)
          verb = route_verb(route)
          target_nickname = path_route_nickname(path, route)

          defined_nicknames.each do |nickname|
            return true if nickname == target_nickname
          end

          false
        end

        def generate_resource(path, apis, models, settings, root, config)
          base_path = if config[:exclude_api_version_in_path]
            config[:base_path] + '/'
          else
            root["basePath"]
          end

          metadata = ApiDeclarationFileMetadata.new(
            root["apiVersion"],
            path,
            base_path,
            settings[:controller_base_path],
            camelize_model_properties: config.
              fetch(:camelize_model_properties, true),
            swagger_version:           root["swaggerVersion"],
            authorizations:            root[:authorizations])

          declaration = ApiDeclarationFile.new(metadata, apis, models)
          declaration.generate_resource
        end

        def routes
          Config.base_applications.map{|app| app.routes.routes.to_a }.flatten
        end

        def get_route_path_apis(path, route, klass, settings, config)
          models, apis = {}, []
          action = route.defaults[:action]
          verb = route_verb(route)

          if !operations = klass.swagger_actions[action.to_sym]
            return {apis: apis, models: models, nickname: nil}
          end

          operations = Hash[
            operations.map do |k, v|
              [
                k.to_s.gsub("@","").to_sym,
                v.respond_to?(:deep_dup) ? v.deep_dup : v.dup
              ]
            end
          ] # rename :@instance hash keys
          operations[:method] = verb
          nickname = operations[:nickname] = path_route_nickname(path, route)

          route_path = if defined?(route.path.spec)
            route.path.spec
          else
            route.path
          end

          api_path = transform_spec_to_api_path(
            route_path,
            settings[:controller_base_path],
            config[:api_extension_type],
          )

          if operations[:parameters]
            operations[:parameters] = filter_path_params(
              api_path,
              operations[:parameters]
            )
          end

          apis << {path: api_path, operations: [operations]}
          models = get_klass_models(klass)

          {apis: apis, models: models, nickname: nickname}
        end

        def get_klass_models(klass)
          models = {}
          # Add any declared models to the root of the resource.
          klass.swagger_models.each do |model_name, model|
            formatted_model = {
              id: model[:id],
              required: model[:required],
              properties: model[:properties],
            }

            if model[:description]
              formatted_model[:description] = model[:description]
            end

            models[model[:id]] = formatted_model
          end
          models
        end

        def get_settings(api_version, config)
          base_path = SlashTrimmer.trim_trailing_slashes(
            config[:base_path] || "")
          controller_base_path = SlashTrimmer.trim_leading_slashes(
            config[:controller_base_path] || "")

          unless controller_base_path.empty?
            base_path += "/#{controller_base_path}"
          end

          api_file_path  = config[:api_file_path]
          authorizations = config[:authorizations]

          {
            base_path:            base_path,
            controller_base_path: controller_base_path,
            api_file_path:        api_file_path,
            authorizations:       authorizations,
          }.freeze
        end

        def get_route_paths(controller_base_path)
          paths = routes.map {|i| "#{i.defaults[:controller]}" }
          paths.uniq.select {|i| i.start_with?(controller_base_path) }
        end

        def create_output_paths(api_file_path)
          FileUtils.mkdir_p(api_file_path)
        end

        def clean_output_paths(api_file_path)
          Dir.foreach(api_file_path) do |f|
            fn = File.join(api_file_path, f)

            if !File.directory?(fn) && File.extname(fn) == '.json'
              File.delete(fn)
            end
          end
        end

        def write_to_file(path, structure, config={})
          content = case config[:formatting]
          when :pretty
            JSON.pretty_generate structure
          else
            structure.to_json
          end

          FileUtils.mkdir_p File.dirname(path)
          File.open(path, 'w') {|file| file.write content }
        end

        def filter_path_params(path, params)
          params.reject do |param|
            param_as_variable = "{#{param[:name]}}"
            param[:param_type] == :path && !path.include?(param_as_variable)
          end
        end
      end
    end
  end
end
