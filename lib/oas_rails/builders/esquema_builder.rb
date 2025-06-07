module OasRails
  module Builders
    module EsquemaBuilder
      class << self
        # Builds a schema for a class when it is used as incoming API data.
        #
        # @param klass [Class] The class for which the schema is built.
        # @return [Hash] The schema as a JSON-compatible hash.
        def build_incoming_schema(klass:, model_to_schema_class: EasyTalk)
          build_schema(
            klass: klass,
            model_to_schema_class: model_to_schema_class,
            excluded_columns: OasRails.config.excluded_columns_incoming,
            exclude_primary_key: true
          )
        end

        # Builds a schema for a class when it is used as outgoing API data.
        # Optionally includes associations if include_associations is provided.
        # @param klass [Class] The class for which the schema is built.
        # @param include_associations [Array<String>] Associations to include in the schema.
        # @return [Hash] The schema as a JSON-compatible hash.
        def build_outgoing_schema(klass:, model_to_schema_class: EasyTalk, include_associations: nil)
          build_schema(
            klass: klass,
            model_to_schema_class: model_to_schema_class,
            excluded_columns: OasRails.config.excluded_columns_outgoing,
            exclude_primary_key: false,
            include_associations: include_associations
          )
        end

        private

        # Recursively build a schema for a model and its associations using ActiveRecord reflection.
        def build_reflection_schema(klass, include_associations = nil)
          # Build properties for columns
          properties = {}
          klass.columns_hash.each do |name, col|
            property = case col.type
              when :integer
                h = { type: 'integer' }
                h[:default] = col.default.to_i unless col.default.nil?
                h
              when :float
                h = { type: 'number', format: 'float' }
                h[:default] = col.default.to_f unless col.default.nil?
                h
              when :decimal
                h = { type: 'number', format: 'double' }
                h[:default] = col.default.to_f unless col.default.nil?
                h
              when :boolean
                h = { type: 'boolean' }
                unless col.default.nil?
                  h[:default] =
                    if col.default == true || col.default == false
                      col.default
                    else
                      ["t", "1", 1, true].include?(col.default) ? true : false
                    end
                end
                h
              when :datetime
                h = { type: 'string', format: 'date-time' }
                h[:default] = col.default.to_s unless col.default.nil?
                h
              when :date
                h = { type: 'string', format: 'date' }
                h[:default] = col.default.to_s unless col.default.nil?
                h
              else
                h = { type: 'string' }
                h[:default] = col.default.to_s unless col.default.nil?
                h
            end
            properties[name] = property
          end

          # Only support flat includes (single-level associations)
          if include_associations && klass.respond_to?(:reflect_on_association)
            assocs = include_associations.is_a?(Array) ? include_associations : [include_associations]
            assocs.each do |assoc_name|
              reflection = klass.reflect_on_association(assoc_name.to_sym)
              next unless reflection
              assoc_klass = reflection.klass rescue nil
              next unless assoc_klass
              assoc_schema = build_reflection_schema(assoc_klass, nil)
              if reflection.collection?
                properties[assoc_name.to_s] = { type: 'array', items: assoc_schema }
              else
                properties[assoc_name.to_s] = assoc_schema
              end
            end
          end

          { type: 'object', properties: properties }
        end

        # Builds a schema with the given configuration.
        # Optionally includes associations if include_associations is provided.
        # @param klass [Class] The class for which the schema is built.
        # @param model_to_schema_class [Class] The schema builder class.
        # @param excluded_columns [Array] Columns to exclude from the schema.
        # @param exclude_primary_key [Boolean] Whether to exclude the primary key.
        # @param include_associations [Array<String>] Associations to include in the schema.
        # @return [Hash] The schema as a JSON-compatible hash.
        def build_schema(klass:, model_to_schema_class:, excluded_columns:, exclude_primary_key:, include_associations: nil)
          if include_associations && klass.respond_to?(:reflect_on_association)
            # Use only the reflection-based builder for includes
            return build_reflection_schema(klass, include_associations)
          end
          # Otherwise, use the builder for the base model
          configure_common_settings(model_to_schema_class: model_to_schema_class)
          model_to_schema_class.configuration.excluded_columns = excluded_columns
          model_to_schema_class.configuration.exclude_primary_key = exclude_primary_key
          definition = model_to_schema_class::ActiveRecordSchemaBuilder.new(klass).build_schema_definition
          puts "[DEBUG] Raw schema definition: #{definition.inspect}"
          patch_constraints_defaults!(definition, klass)
          schema = EasyTalk::Builders::ObjectBuilder.new(definition).build.as_json
          fix_schema_default_types!(schema, klass)
          schema
        end

        # Recursively fix default value types in the schema hash to match the column types, at any nesting level
        def fix_schema_default_types!(schema, klass)
          return unless schema.is_a?(Hash)
          schema.each do |key, value|
            # Fix default if this is a property hash with a default
            if (key.to_s == 'properties' && value.is_a?(Hash))
              value.each do |prop_name, prop|
                col = klass.columns_hash[prop_name.to_s] rescue nil
                next unless col && prop.is_a?(Hash)
                prop.each do |k, v|
                  if k.to_s == 'default'
                    prop[k] =
                      case col.type
                      when :integer
                        v.is_a?(String) ? v.to_i : v
                      when :float, :decimal
                        v.is_a?(String) ? v.to_f : v
                      when :boolean
                        if v == true || v == false
                          v
                        else
                          ["t", "1", 1, true].include?(v) ? true : false
                        end
                      else
                        v
                      end
                  end
                end
                # Recurse into nested property schemas (for objects/arrays)
                fix_schema_default_types!(prop, klass)
              end
            elsif value.is_a?(Hash)
              fix_schema_default_types!(value, klass)
            elsif value.is_a?(Array)
              value.each { |item| fix_schema_default_types!(item, klass) if item.is_a?(Hash) }
            end
          end
        end

        # Configures common settings for schema building.
        #
        # Excludes associations and foreign keys from the schema by default.
        def configure_common_settings(model_to_schema_class: EasyTalk)
          model_to_schema_class.configuration.exclude_associations = true
        end

        # Patch constraints[:default] in the schema definition for correct types
        def patch_constraints_defaults!(definition, klass)
          schema = definition.instance_variable_get(:@schema)
          return unless schema.is_a?(Hash) && schema[:properties].is_a?(Hash)
          schema[:properties].each do |name, prop|
            col = klass.columns_hash[name.to_s] rescue nil
            next unless col && prop.is_a?(Hash) && prop[:constraints].is_a?(Hash) && prop[:constraints].key?(:default)
            val = prop[:constraints][:default]
            prop[:constraints][:default] =
              case col.type
              when :integer
                val.is_a?(String) ? val.to_i : val
              when :float, :decimal
                val.is_a?(String) ? val.to_f : val
              when :boolean
                if val == true || val == false
                  val
                else
                  ["t", "1", 1, true].include?(val) ? true : false
                end
              else
                val
              end
          end
        end
      end
    end
  end
end
