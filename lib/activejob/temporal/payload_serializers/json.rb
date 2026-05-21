# frozen_string_literal: true

module ActiveJob
  module Temporal
    module PayloadSerializers
      module Json
        module_function

        def dump(payload)
          payload
        end

        def load(payload)
          payload
        end

        def envelope?(_payload)
          false
        end
      end
    end
  end
end
