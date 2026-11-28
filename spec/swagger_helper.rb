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
          Public, anonymous reads for the Arcadary launcher; authenticated capture-device uploads and private admin staging. JSON routes end in .json; screenshot delivery ends in .png. Generated from the request specs in spec/requests; do not edit swagger/ by hand.

          Catalog data originates from [No-Intro](https://no-intro.org/), sourced through [libretro-database at f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029](https://github.com/libretro/libretro-database/tree/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro). Arcadary imports checksum metadata, groups releases into games, normalizes titles/regions/revisions and applies explicit launcher identity mappings. The entire service catalog, including project corrections, additions and later metadata fields, is licensed under [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/), as is the [upstream source at the pin](https://github.com/libretro/libretro-database/blob/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/LICENSE). Screenshot images and all video are excluded: each medium's own rights apply. Catalog and screenshot licences grant no video rights. The owner-approved exception permits authenticated private HLS staging and delivery, including the private Donkey Kong trial, without public commercial-footage distribution or anonymous playthrough metadata. Internal HLS validation leaves all bytes private; expiry and bounded private reclamation retain terminal receipts; publication and delivery arrive separately. Application code remains MIT.

          The pinned NES DAT includes distinct headered .nes and unheadered .unh releases. A launcher hashing NES payload bytes without the iNES header sends the matching unheadered checksum. All eight lists are covered, including C64 tape metadata; catalog coverage does not imply launcher playback support. No game files or player filenames are received, stored or served.

          Optional release.controller_profile supplies version 1 original SNES face-button positions/labels and literal gameplay prompt letters for that exact stable release only. Each shared-media candidate retains its own facts; missing profiles are omitted, without defaults, candidate selection or edition inference. Public profiles exclude binding and evidence. Internal create_release/correct_release authoring accepts a whole profile or null to clear, under the revision/retry/audit contract; combined media edits require complete preview. The authored schema additionally requires binding matching system/region/revision (nullable edition strings, at most 128 characters) and 1–8 nonblank text citations per fact, each at most 500 characters. No images, clips, manual scans, file bytes, file names or game-file download locations in evidence. See README's Original controller layout and prompts and Catalog authoring sections for the internal contract. Profile corrections refresh release/media ETags and Last-Modified with existing cache lifetimes; reads remain anonymous and caller-independent. Controller classification, physical label/symbol mapping and local preferences belong to the launcher. No device/controller identity or choice is received. No real Zelda profile is populated; owner confirmation of exact identity, edition and textual evidence gates trial use only, not merge or issue closure. Publication and deployment remain outside scope.

          Release screenshots are ordered title then gameplay, empty when absent. Embedded game.screenshot is the picture from the lexicographically smallest stable release.id among that game's releases with screenshots, choosing gameplay then title, or null. This ordering does not recommend a release for playback. Each image exposes exactly kind, url, width, height and licence; licence is an empty string when no image licence is granted. Uploading grants no new rights. URLs use SCREENSHOT_PUBLIC_BASE_URL plus /v1/screenshots/{sha256}.png, with SHA-256 measured from the stored PNG, without signed/expiring parameters. Screenshot changes invalidate release and media validators, including sibling releases when the selected game picture changes.

          Image credits keyed by game.id: ucity — µCity graphics by AntonioND/SkyLyrac (Antonio Niño Díaz), [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/), [upstream v1.3 notice](https://github.com/AntonioND/ucity/blob/v1.3/readme.rst#license). tobu-tobu-girl — Tobu Tobu Girl assets by Tangram Games, [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/), [upstream notice](https://github.com/SimonLarsen/tobutobugirl/blob/048a22c2d7ebbe25811322e8692803fa86bb643a/README.md#license). Arcadary re-encodes captures as pixel-only PNGs, removing metadata. Launchers can attribute using game.id and the image's public licence value together with these credits.

          Image URLs identify releases; the service and CDN see callers' IP addresses. Reads are anonymous, not private. Uploads and authentication responses are never shared-cacheable. Takedown requests: takedown@arcadary.org. Origin removal cannot erase cached copies. Before public launch the deployment owner must verify CDN purging, delivery-layer access-log suppression, and that the alias accepts mail and forwards to a monitored inbox.
        TEXT
      },
      paths: {},
      components: {
        securitySchemes: { capture_token: { type: :http, scheme: :bearer }, private_service_basic: { type: :http, scheme: :basic } },
        schemas: {
          playthrough_declaration: McpPlaythroughToolsService.input_schema,
          Screenshot: screenshot_schema,
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
          DeviceCompatibility: {
            description: 'The newest result recorded for this device class under the release\'s current startup.revision, or unknown when there is none. unknown carries only status and never stops a launch. works, attention (a recorded problem, such as performance, explained in one sentence) and does_not_work name the core and version tested, the launch configuration (startup_revision) and test time, with a short public reason sentence (required for attention, optional for does_not_work, null for works), what the reviewer saw (observed) and what the test did not cover (limits). requires_input lists input devices besides the controller (keyboard, mouse) that the release needs to be playable on this device class, empty when none; it is separate from status: the launcher shows attention while a listed device is not connected, and does_not_work outranks attention. No state blocks Play. Compare core and core_version with your own before treating a result as yours.',
            oneOf: [
              { type: :object, required: %w[status], additionalProperties: false, properties: { status: { type: :string, enum: %w[unknown] } } },
              {
                type: :object, required: %w[status reason core core_version startup_revision tested_at observed limits requires_input], additionalProperties: false,
                properties: {
                  status: { type: :string, enum: %w[works attention does_not_work] }, reason: { type: :string, nullable: true, minLength: 1, maxLength: 200 },
                  core: { type: :string, pattern: '^[a-z0-9][a-z0-9_.-]{0,63}$' },
                  core_version: { type: :string, minLength: 1, maxLength: 100 }, startup_revision: { type: :string, pattern: '^[0-9a-f]{64}$' },
                  tested_at: { type: :string, format: 'date-time' }, observed: { type: :string, minLength: 1, maxLength: 500 },
                  limits: { type: :string, minLength: 1, maxLength: 500 },
                  requires_input: { type: :array, uniqueItems: true, items: { type: :string, enum: %w[keyboard mouse] } }
                }
              }
            ]
          },
          Compatibility: {
            type: :object, required: %w[steam_machine steam_deck], additionalProperties: false,
            description: 'Playability per device class, recorded by a named reviewer who owns and played the exact file. A Steam Machine result says nothing about Steam Deck. Recording a result refreshes this release\'s and its media\'s validators.',
            properties: { steam_machine: { "$ref" => "#/components/schemas/DeviceCompatibility" }, steam_deck: { "$ref" => "#/components/schemas/DeviceCompatibility" } }
          },
          Release: {
            type: :object, required: %w[release game media startup], additionalProperties: false,
            properties: {
              release: {
                type: :object, required: %w[id sha1 system region revision screenshots compatibility], additionalProperties: false,
                properties: {
                  id: { type: :string }, sha1: { type: :string, pattern: "^[0-9a-f]{40}$" },
                  system: { type: :string, enum: %w[nes snes gb gbc megadrive pcengine atari2600 c64] },
                  region: { type: :string, nullable: true }, revision: { type: :string, nullable: true },
                  controller_profile: { "$ref" => "#/components/schemas/ControllerProfile" },
                  screenshots: { type: :array, items: { "$ref" => "#/components/schemas/Screenshot" } },
                  compatibility: { "$ref" => "#/components/schemas/Compatibility" }
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

  schemas = config.openapi_specs.fetch('v1/swagger.yaml').fetch(:components).fetch(:schemas)
  declaration_properties = schemas.fetch(:playthrough_declaration).fetch(:properties)
  schemas[:playthrough_validation_result] = {
    type: :object, additionalProperties: false,
    required: %w[staging_id declaration_sha256 package_sha256 manifest release_id source_sha1 capture verification root duration video_codec audio_codec chapters_path chapters],
    properties: {
      staging_id: { type: :string }, declaration_sha256: { type: :string, pattern: '^[0-9a-f]{64}$' },
      package_sha256: { type: :string, pattern: '^[0-9a-f]{64}$' }, manifest: declaration_properties.fetch(:manifest),
      release_id: declaration_properties.fetch(:release_id), source_sha1: declaration_properties.fetch(:source_sha1),
      capture: declaration_properties.fetch(:capture), verification: declaration_properties.fetch(:verification).merge(nullable: true),
      root: { type: :string, enum: [ 'index.m3u8' ] }, duration: { type: :string, pattern: '^[0-9]+\.[0-9]+$', description: 'Exact summed EXTINF seconds as a decimal string.' },
      video_codec: { type: :string, enum: [ 'h264' ] }, audio_codec: { type: :string, nullable: true, enum: [ 'aac', nil ] },
      chapters_path: { type: :string, nullable: true, enum: [ 'chapters.vtt', nil ] },
      chapters: { type: :array, maxItems: 256, items: {
        type: :object, additionalProperties: false, required: %w[start end title], properties: {
          start: { type: :string, pattern: '^[0-9]{2}:[0-5][0-9]:[0-5][0-9]\.[0-9]{3}$' },
          end: { type: :string, pattern: '^[0-9]{2}:[0-5][0-9]:[0-5][0-9]\.[0-9]{3}$' }, title: { type: :string, minLength: 1 }
        }
      } }
    }
  }

  # Specify the format of the output Swagger file when running 'rswag:specs:swaggerize'.
  # The openapi_specs configuration option has the filename including format in
  # the key, this may want to be changed to avoid putting yaml in json files.
  # Defaults to json. Accepts ':json' and ':yaml'.
  config.openapi_format = :yaml
end
