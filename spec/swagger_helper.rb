# frozen_string_literal: true

require 'rails_helper'

screenshot_schema = {
  type: :object, required: %w[kind url width height licence], additionalProperties: false,
  properties: {
    kind: { type: :string, enum: %w[title gameplay] },
    url: { type: :string, format: :uri, pattern: '^https://' },
    width: { type: :integer, minimum: 1 }, height: { type: :integer, minimum: 1 }, licence: { type: :string }
  }
}

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
          Public, anonymous reads for the Arcadary launcher, and authenticated admin uploads. JSON routes end in .json. Generated from the request specs in spec/requests; do not edit swagger/ by hand.

          Catalog data originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). Arcadary imports checksum metadata, groups releases into games, normalizes titles/regions/revisions and applies explicit launcher identity mappings. The entire service catalog, including project corrections, additions and later metadata fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/), as is the [upstream source at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE). Screenshot images and all video are excluded: each medium's own rights apply. Catalog and screenshot licences grant no video rights. The owner-approved exception permits authenticated private HLS uploads, including the private Donkey Kong trial, without public commercial-footage distribution or anonymous playthrough metadata; uploaded playthroughs stay private. Application code remains MIT.

          The pinned NES DAT includes distinct headered .nes and unheadered .unh releases. A launcher hashing NES payload bytes without the iNES header sends the matching unheadered checksum. All eight lists are covered, including C64 tape metadata; catalog coverage does not imply launcher playback support. No game files or player filenames are received, stored or served.

          Optional release.controller_profile supplies version 1 original SNES face-button positions/labels and literal gameplay prompt letters for that exact stable release only. Each shared-media candidate retains its own facts; missing profiles are omitted, without defaults, candidate selection or edition inference. Public profiles exclude binding and evidence. Internal create_release/correct_release authoring accepts a whole profile or null to clear, under the revision/retry/audit contract; combined media edits require complete preview. The authored schema additionally requires binding matching system/region/revision (nullable edition strings, at most 128 characters) and 1–8 nonblank text citations per fact, each at most 500 characters. No images, clips, manual scans, file bytes, file names or game-file download locations in evidence. See README's Original controller layout and prompts and Catalog authoring sections for the internal contract. Profile corrections refresh release/media ETags and Last-Modified with existing cache lifetimes; reads remain anonymous and caller-independent. Controller classification, physical label/symbol mapping and local preferences belong to the launcher. No device/controller identity or choice is received. No real Zelda profile is populated; owner confirmation of exact identity, edition and textual evidence gates trial use only, not merge or issue closure. Publication and deployment remain outside scope.

          Release screenshots are ordered title then gameplay, empty when absent. Embedded game.screenshot is the picture from the lexicographically smallest stable release.id among that game's releases with screenshots, choosing gameplay then title, or null. This ordering does not recommend a release for playback. Each image exposes exactly kind, url, width, height and licence; licence is an empty string when no image licence is granted. Uploading grants no new rights. URLs are the public media host (https://media.arcadary.org in production) plus /screenshots/{sha256}.png, with SHA-256 measured from the stored PNG, without signed/expiring parameters. Screenshot changes invalidate release and media validators, including sibling releases when the selected game picture changes.

          Image credits keyed by game.id: ucity — µCity graphics by AntonioND/SkyLyrac (Antonio Niño Díaz), [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/), [upstream v1.3 notice](https://github.com/AntonioND/ucity/blob/v1.3/readme.rst#license). tobu-tobu-girl — Tobu Tobu Girl assets by Tangram Games, [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/), [upstream notice](https://github.com/SimonLarsen/tobutobugirl/blob/048a22c2d7ebbe25811322e8692803fa86bb643a/README.md#license). Arcadary re-encodes captures as pixel-only PNGs, removing metadata. Launchers can attribute using game.id and the image's public licence value together with these credits.

          Image URLs identify releases; the service and CDN see callers' IP addresses. Reads are anonymous, not private. Uploads and authentication responses are never shared-cacheable. Takedown requests: takedown@arcadary.org. Origin removal cannot erase cached copies. Before public launch the deployment owner must verify CDN purging, delivery-layer access-log suppression, and that the alias accepts mail and forwards to a monitored inbox.
        TEXT
      },
      paths: {},
      components: {
        securitySchemes: { private_service_basic: { type: :http, scheme: :basic } },
        schemas: {
          Screenshot: screenshot_schema,
          Upload: McpUploadToolsService::UPLOAD,
          UploadFile: McpUploadToolsService::FILE,
          ControllerProfile: {
            type: :object, required: %w[version layout prompts], additionalProperties: false,
            description: 'Optional exact-release original SNES layout and literal gameplay prompt letters. Positions face the controller buttons. No system defaults or edition inference. Binding and text citations remain internal. Controller classification, physical label/symbol mapping and preferences belong to the launcher. The Zelda trial is unconfirmed pending owner confirmation of the stable release ID, checksum, edition and textual evidence; no real trial profile is populated.',
            properties: {
              version: { type: :integer, enum: [ 1 ] },
              layout: {
                type: :array, minItems: 4, maxItems: 4,
                items: {
                  type: :object, required: %w[position label], additionalProperties: false,
                  properties: { position: { type: :string, enum: %w[top right bottom left] }, label: { type: :string, enum: %w[X A B Y] } }
                }
              },
              prompts: {
                type: :array, maxItems: 16,
                items: {
                  type: :object, required: %w[letter position], additionalProperties: false,
                  properties: { letter: { type: :string, pattern: '^[A-Za-z]$', minLength: 1, maxLength: 1 }, position: { type: :string, enum: %w[top right bottom left] } }
                }
              }
            }
          },
          Release: {
            type: :object, required: %w[release game media startup compatibility], additionalProperties: false,
            properties: {
              release: {
                type: :object, required: %w[id sha1 system region revision screenshots], additionalProperties: false,
                properties: {
                  id: { type: :string }, sha1: { type: :string, pattern: "^[0-9a-f]{40}$" },
                  system: { type: :string, enum: %w[nes snes gb gbc megadrive pcengine atari2600 c64] },
                  region: { type: :string, nullable: true }, revision: { type: :string, nullable: true },
                  controller_profile: { "$ref" => "#/components/schemas/ControllerProfile" },
                  screenshots: { type: :array, items: { "$ref" => "#/components/schemas/Screenshot" } }
                }
              },
              game: {
                type: :object, required: %w[id title screenshot], additionalProperties: false,
                properties: { id: { type: :string }, title: { type: :string }, screenshot: screenshot_schema.merge(nullable: true) }
              },
              media: {
                type: :array, minItems: 1,
                items: {
                  type: :object, required: %w[key position label role sha1 size format], additionalProperties: false,
                  properties: {
                    key: { type: :string, pattern: "^[a-z0-9-]{1,32}$" }, position: { type: :integer, minimum: 1 },
                    label: { type: :string, nullable: true, maxLength: 80 }, role: { type: :string, enum: %w[game save] },
                    sha1: { type: :string, pattern: "^[0-9a-f]{40}$" }, size: { type: :integer, minimum: 0, nullable: true },
                    format: { type: :string, pattern: "^[a-z0-9]+$", nullable: true }
                  }
                }
              },
              startup: {
                type: :object, required: %w[schema boot drives revision], additionalProperties: false,
                properties: {
                  schema: { type: :integer, enum: [ 1 ] }, boot: { type: :string },
                  drives: { type: :object, additionalProperties: false, properties: { "8" => { type: :string }, "9" => { type: :string } } },
                  revision: { type: :string, pattern: "^[0-9a-f]{64}$" }
                }
              },
              compatibility: {
                type: :object, required: %w[default_state results], additionalProperties: false,
                description: "Tested playability, kept apart from identity. Any environment without a result is default_state.",
                properties: {
                  default_state: { type: :string, enum: [ "unknown" ] },
                  results: { type: :array, items: {
                    type: :object, additionalProperties: false,
                    required: %w[id device_class core core_version startup_revision state tested_at evidence limitations],
                    description: "The verdict in force for one environment: a reviewer who owns the exact file played it on this device class, core version and launch configuration.",
                    properties: {
                      id: { type: :integer }, device_class: { type: :string, enum: CompatibilityVerdict::DEVICE_CLASSES },
                      core: { type: :string }, core_version: { type: :string }, startup_revision: { type: :string, pattern: "^[0-9a-f]{64}$" },
                      state: { type: :string, enum: CompatibilityVerdict::STATES - [ "unknown" ] }, tested_at: { type: :string, format: "date-time" },
                      evidence: { type: :string }, limitations: { type: :string, nullable: true }
                    }
                  } }
                }
              }
            }
          }
        }
      },
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
