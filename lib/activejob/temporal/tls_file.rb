# frozen_string_literal: true

module ActiveJob
  module Temporal
    module TLSFile
      class Error < StandardError; end
      # Symlinks are resolved before opening, so NOFOLLOW only trips when the
      # resolved path is swapped for a symlink between resolution and open.
      OPEN_FLAGS = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)

      module_function

      # @param path [String, nil] path to a TLS file, symlinks allowed
      # @return [Boolean] true when the path resolves to a readable regular file
      def readable_regular_file?(path)
        resolved_path = File.realpath(File.expand_path(path))

        File.stat(resolved_path).file? && File.readable?(resolved_path)
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::ELOOP
        false
      end

      # Reads a TLS file, resolving symlinks first so Kubernetes secret mounts
      # (path -> ..data/path -> timestamped directory) work.
      #
      # @param path [String, nil] path to a TLS file
      # @return [String, nil] file contents, or nil when path is blank
      # @raise [Error] when the path does not resolve to a readable regular file
      def read(path)
        return nil if path.nil? || path.to_s.empty?

        resolved_path = File.realpath(File.expand_path(path))
        File.open(resolved_path, OPEN_FLAGS) do |file|
          raise Error, "TLS file path must point to a regular file: #{path}" unless file.stat.file?

          file.read
        end
      rescue Errno::ELOOP
        raise Error, "TLS file path could not be resolved: #{path}"
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
        raise Error, "TLS file path is not readable: #{path}"
      end
    end
  end
end
