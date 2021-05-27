# frozen_string_literal: true

module JsonbAccessor
  module Macro
    module ClassMethods
      def jsonb_accessor(jsonb_attribute, field_types)
        names_and_store_keys = field_types.each_with_object({}) do |(name, type), mapping|
          _type, options = Array(type)
          mapping[name.to_s] = (options.try(:delete, :store_key) || name).to_s
        end

        # Defines virtual attributes for each jsonb field.
        field_types.each do |name, type|
          next attribute name, type unless type.is_a?(Array)
          next attribute name, *type unless type.last.is_a?(Hash)

          *args, keyword_args = type
          attribute name, *args, **keyword_args
        end

        store_key_mapping_method_name = "jsonb_store_key_mapping_for_#{jsonb_attribute}"
        # Defines methods on the model class
        class_methods = Module.new do
          # Allows us to get a mapping of field names to store keys scoped to the column
          define_method(store_key_mapping_method_name) do
            superclass_mapping = superclass.try(store_key_mapping_method_name) || {}
            superclass_mapping.merge(names_and_store_keys)
          end
        end
        # We extend with class methods here so we can use the results of methods it defines to define more useful methods later
        extend class_methods

        # Get field names to default values mapping
        names_and_defaults = field_types.each_with_object({}) do |(name, type), mapping|
          _type, options = Array(type)
          field_default = options.try(:delete, :default)
          mapping[name.to_s] = field_default unless field_default.nil?
        end

        # Get store keys to default values mapping
        store_keys_and_defaults = ::JsonbAccessor::QueryHelper.convert_keys_to_store_keys(names_and_defaults, public_send(store_key_mapping_method_name))

        # Define jsonb_defaults_mapping_for_<jsonb_attribute>
        defaults_mapping_method_name = "jsonb_defaults_mapping_for_#{jsonb_attribute}"
        class_methods.instance_eval do
          define_method(defaults_mapping_method_name) do
            superclass_mapping = superclass.try(defaults_mapping_method_name) || {}
            superclass_mapping.merge(store_keys_and_defaults)
          end
        end

        all_defaults_mapping = public_send(defaults_mapping_method_name)
        # Fields may have procs as default value. This means `all_defaults_mapping` may contain procs as values. To make this work
        # with the attributes API, we need to wrap `all_defaults_mapping` with a proc itself, making sure it returns a plain hash
        # each time it is evaluated.
        all_defaults_mapping_proc =
          if all_defaults_mapping.present?
            -> { all_defaults_mapping.transform_values { |value| value.respond_to?(:call) ? value.call : value }.to_h.compact }
          end
        attribute jsonb_attribute, :jsonb, default: all_defaults_mapping_proc if all_defaults_mapping_proc.present?

        # Setters are in a module to allow users to override them and still be able to use `super`.
        setters = Module.new do
          # Overrides the setter created by `attribute` above to make sure the jsonb attribute is kept in sync.
          names_and_store_keys.each do |name, store_key|
            define_method("#{name}=") do |value|
              super(value)

              attribute_value = public_send(name)
              # Rails always saves time based on `default_timezone`. Since #as_json considers timezone, manual conversion is needed
              if attribute_value.acts_like?(:time)
                default_timezone = ActiveRecord::Base.default_timezone
                attribute_value = (default_timezone == :utc ? attribute_value.utc : attribute_value.in_time_zone).strftime("%FT%R:%S.%LZ")
              end

              new_values = (public_send(jsonb_attribute) || {}).merge(store_key => attribute_value)
              write_attribute(jsonb_attribute, new_values)
            end
          end

          # Overrides the jsonb attribute setter to make sure the jsonb fields are kept in sync.
          define_method("#{jsonb_attribute}=") do |value|
            value ||= {}
            names_to_store_keys = self.class.public_send(store_key_mapping_method_name)

            # this is the raw hash we want to save in the jsonb_attribute
            value_with_store_keys = ::JsonbAccessor::QueryHelper.convert_keys_to_store_keys(value, names_to_store_keys)
            write_attribute(jsonb_attribute, value_with_store_keys)

            # this maps attributes to values
            value_with_named_keys = ::JsonbAccessor::QueryHelper.convert_store_keys_to_keys(value, names_to_store_keys)

            empty_named_attributes = names_to_store_keys.transform_values { nil }
            empty_named_attributes.merge(value_with_named_keys).each do |name, attribute_value|
              write_attribute(name, attribute_value)
            end
          end
        end
        include setters

        # Makes sure new objects have the appropriate values in their jsonb fields.
        after_initialize do
          if has_attribute?(jsonb_attribute)
            jsonb_values = public_send(jsonb_attribute) || {}
            jsonb_values.each do |store_key, value|
              name = names_and_store_keys.key(store_key)
              next unless name

              write_attribute(name, value)
              clear_attribute_change(name) if persisted?
            end
          end
        end

        unless superclass.respond_to? store_key_mapping_method_name
          # <jsonb_attribute>_where scope
          define_singleton_method "#{jsonb_attribute}_where" do |attributes|
            store_key_attributes = ::JsonbAccessor::QueryHelper.convert_keys_to_store_keys(attributes, all.model.public_send(store_key_mapping_method_name))
            jsonb_where(jsonb_attribute, store_key_attributes)
          end

          # <jsonb_attribute>_where_not scope
          define_singleton_method "#{jsonb_attribute}_where_not" do |attributes|
            store_key_attributes = ::JsonbAccessor::QueryHelper.convert_keys_to_store_keys(attributes, all.model.public_send(store_key_mapping_method_name))
            jsonb_where_not(jsonb_attribute, store_key_attributes)
          end

          # <jsonb_attribute>_order scope
          define_singleton_method "#{jsonb_attribute}_order" do |*args|
            ordering_options = args.extract_options!
            order_by_defaults = args.each_with_object({}) { |attribute, config| config[attribute] = :asc }
            store_key_mapping = all.model.public_send(store_key_mapping_method_name)

            order_by_defaults.merge(ordering_options).reduce(all) do |query, (name, direction)|
              key = store_key_mapping[name.to_s]
              order_query = jsonb_order(jsonb_attribute, key, direction)
              query.merge(order_query)
            end
          end
        end
      end
    end
  end
end
