# frozen_string_literal: true

module ActiveJob
  module Temporal
    module RailsEnvironmentLoader
      class Error < StandardError; end

      Result = Struct.new(:loaded, :rails_root, :environment_path, :warnings, keyword_init: true) do
        def loaded?
          loaded
        end
      end

      UNSAFE_WRITE_BITS = 0o022

      module_function

      def load!(rails_root:, warning_io: $stderr, require_environment: Kernel.method(:require))
        result = resolve(rails_root)
        result.warnings.each { |warning| warning_io.puts(warning) }
        return result unless result.loaded?

        require_environment.call(result.environment_path)
        eager_load_rails_application
        result
      end

      def resolve(rails_root)
        explicit_root = rails_root != "."
        expanded_root = File.expand_path(rails_root)
        return missing_root_result(expanded_root, explicit_root) unless File.directory?(expanded_root)

        resolve_existing_root(rails_root, explicit_root, File.realpath(expanded_root))
      rescue Errno::EACCES => e
        raise Error, "Cannot inspect Rails application at: #{expanded_root} (#{e.message})"
      end

      def resolve_existing_root(rails_root, explicit_root, canonical_root)
        paths = rails_paths(canonical_root)
        return non_rails_result(canonical_root, rails_root, explicit_root) unless File.file?(paths.fetch(:application))

        environment_path = paths.fetch(:environment)
        raise Error, "Cannot find Rails environment at: #{environment_path}" unless File.file?(environment_path)

        canonical_paths = canonicalize_paths(
          canonical_root,
          paths.fetch(:config),
          paths.fetch(:application),
          environment_path
        )
        validate_paths_stay_under_root!(canonical_root, canonical_paths)
        validate_paths_not_writable_by_group_or_world!(canonical_paths)

        Result.new(
          loaded: true,
          rails_root: canonical_root,
          environment_path: canonical_paths.fetch(environment_path),
          warnings: owner_warnings(canonical_paths.values)
        )
      end

      def rails_paths(canonical_root)
        config_path = File.join(canonical_root, "config")
        {
          config: config_path,
          application: File.join(config_path, "application.rb"),
          environment: File.join(config_path, "environment.rb")
        }
      end

      def missing_root_result(expanded_root, explicit_root)
        raise Error, "Cannot find Rails application at: #{expanded_root}" if explicit_root

        Result.new(loaded: false, rails_root: expanded_root, environment_path: nil, warnings: [])
      end

      def non_rails_result(canonical_root, rails_root, explicit_root)
        warnings = explicit_root ? non_rails_warnings(rails_root) : []
        Result.new(loaded: false, rails_root: canonical_root, environment_path: nil, warnings: warnings)
      end

      def canonicalize_paths(*paths)
        paths.to_h { |path| [path, File.realpath(path)] }
      end

      def validate_paths_stay_under_root!(canonical_root, canonical_paths)
        escaped_path = canonical_paths.values.find { |path| !path_under_root?(canonical_root, path) }
        return unless escaped_path

        raise Error, "Refusing to load Rails environment path outside RAILS_ROOT: #{escaped_path}"
      end

      def validate_paths_not_writable_by_group_or_world!(paths)
        unsafe_path = paths.values.find { |path| group_or_world_writable?(path) }
        return unless unsafe_path

        raise Error, "refusing to load Rails environment from group- or world-writable path: #{unsafe_path}"
      end

      def path_under_root?(canonical_root, path)
        path == canonical_root || path.start_with?("#{canonical_root}#{File::SEPARATOR}")
      end

      def group_or_world_writable?(path)
        File.stat(path).mode.anybits?(UNSAFE_WRITE_BITS)
      end

      def owner_warnings(paths)
        current_uid = Process.uid
        unsafe_owner_path = paths.find do |path|
          owner_uid = File.stat(path).uid
          owner_uid != current_uid && !owner_uid.zero?
        end
        return [] unless unsafe_owner_path

        [
          "Warning: Rails environment path is not owned by the current user or root: #{unsafe_owner_path}"
        ]
      end

      def non_rails_warnings(rails_root)
        [
          "Warning: #{rails_root} does not appear to be a Rails application",
          "Continuing without Rails environment. Job classes may not be available."
        ]
      end

      def eager_load_rails_application
        return unless Object.const_defined?(:Rails)

        rails = Object.const_get(:Rails)
        rails.application.eager_load! if rails.env.development? || rails.env.test?
      end
    end
  end
end
