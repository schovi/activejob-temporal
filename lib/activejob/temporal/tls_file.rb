# frozen_string_literal: true

module ActiveJob
  module Temporal
    module TLSFile
      class Error < StandardError; end
      OPEN_FLAGS = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
      USES_NOFOLLOW = File.const_defined?(:NOFOLLOW)

      module_function

      def readable_regular_file?(path)
        expanded_path = File.expand_path(path)
        stat = File.lstat(expanded_path)
        return false if stat.symlink?

        stat.file? && File.readable?(expanded_path)
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        false
      end

      def read(path)
        return nil if path.nil? || path.to_s.empty?

        expanded_path = File.expand_path(path)
        reject_symlink!(expanded_path) unless USES_NOFOLLOW
        File.open(expanded_path, OPEN_FLAGS) do |file|
          raise Error, "TLS file path must point to a regular file: #{path}" unless file.stat.file?

          file.read
        end
      rescue Errno::ELOOP
        raise Error, "TLS file path must not be a symlink: #{path}"
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        raise Error, "TLS file path is not readable: #{path}"
      end

      def reject_symlink!(path)
        return unless File.lstat(path).symlink?

        raise Error, "TLS file path must not be a symlink: #{path}"
      end
    end
  end
end
