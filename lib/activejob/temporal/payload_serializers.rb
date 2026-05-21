# frozen_string_literal: true

require_relative "payload_serializers/json"
require_relative "payload_serializers/marshal"
require_relative "payload_serializers/message_pack"

module ActiveJob
  module Temporal
    module PayloadSerializers
      module_function

      ENVELOPE_VERSION = 1
      JSON = :json
      MESSAGE_PACK = :message_pack
      MESSAGE_PACK_ALIAS = :msgpack
      MARSHAL = :marshal
      SUPPORTED = [JSON, MESSAGE_PACK, MESSAGE_PACK_ALIAS, MARSHAL].freeze

      def fetch(name)
        case normalize_name(name)
        when JSON then PayloadSerializers::Json
        when MESSAGE_PACK then PayloadSerializers::MessagePack
        when MARSHAL then PayloadSerializers::Marshal
        else
          raise ConfigurationError, "Unsupported payload serializer: #{name.inspect}"
        end
      end

      def normalize_name(name)
        normalized = name.to_sym
        normalized == MESSAGE_PACK_ALIAS ? MESSAGE_PACK : normalized
      rescue NoMethodError
        name
      end
    end
  end
end
