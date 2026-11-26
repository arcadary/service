# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  # Specify a root folder where Swagger JSON files are generated
  # NOTE: If you're using the rswag-api to serve API descriptions, you'll need
  # to ensure that it's configured to serve Swagger from the same folder
  config.openapi_root = Rails.root.join('swagger').to_s

  # Define one or more Swagger documents and provide global metadata for each one
  # When you run the 'rswag:specs:swaggerize' rake task, the complete Swagger will
  # be generated at the provided relative path under openapi_root
  # By default, the operations defined in spec files are added to the first
  # document below. You can override this behavior by adding a openapi_spec tag to the
  # the root example_group in your specs, e.g. describe '...', openapi_spec: 'v2/swagger.json'
  config.openapi_specs = {
    'v1/swagger.yaml' => {
      openapi: '3.0.1',
      info: {
        title: 'Arcadary service API',
        version: 'v1',
        description: <<~TEXT.strip
          Public, anonymous JSON API for the Arcadary launcher. Generated from the request specs in spec/requests; do not edit swagger/ by hand.

          Catalog data originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). Arcadary imports checksum metadata, groups releases into games, normalizes titles/regions/revisions and applies explicit launcher identity mappings. The entire service catalog, including project corrections, additions and later fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/), as is the [upstream source at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE). Application code remains MIT.

          The pinned NES DAT includes distinct headered .nes and unheadered .unh releases. A launcher hashing NES payload bytes without the iNES header sends the matching unheadered checksum. All eight lists are covered, including C64 tape metadata; catalog coverage does not imply launcher playback support. No game files or player filenames are received, stored or served.
        TEXT
      },
      paths: {},
      servers: [
        { url: '/' }
      ]
    }
  }

  # Specify the format of the output Swagger file when running 'rswag:specs:swaggerize'.
  # The openapi_specs configuration option has the filename including format in
  # the key, this may want to be changed to avoid putting yaml in json files.
  # Defaults to json. Accepts ':json' and ':yaml'.
  config.openapi_format = :yaml
end
