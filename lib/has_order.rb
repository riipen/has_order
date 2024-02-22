# frozen_string_literal: true

require 'active_support'
require 'action_controller'

module HasOrder
  def self.included(base)
    base.class_eval do
      extend ClassMethods

      class_attribute :order_configurations, instance_writer: false
      class_attribute :order_default, instance_writer: false

      self.order_configurations = {}
      self.order_default = %i[-updated_at]
    end
  end

  module ClassMethods
    # Detects the sort order from the url and applies it to the collection
    #
    # == Options
    # * :only   - Only apply the order to the given actions
    # * :except - Do not apply the order to the given actions
    # * :if     - A lambda or symbol that returns true if the order should be applied
    # * :unless - A lambda or symbol that returns true if the order should not be applied
    # * :as     - A alias for the order to apply
    #
    def has_order(order, **options) # rubocop:disable Naming/PredicateName
      options.symbolize_keys!
      options.assert_valid_keys(:only, :except, :if, :unless, :as)

      options[:only] = Array.wrap(options[:only]).map(&:to_sym)
      options[:except] = Array.wrap(options[:except]).map(&:to_sym)
      options[:order] = order.to_sym
      options_key = options[:as].presence || :"#{order}"

      self.order_configurations = order_configurations.dup
      order_configurations[options_key] = options
    end

    # Sets the default order to apply to the collection
    def has_order_default(orders, **options) # rubocop:disable Naming/PredicateName
      before_action options do
        self.class.order_default = orders.is_a?(Array) ? orders.map(&:to_sym) : send(orders)
      end
    end
  end

  protected

  # Recieves an object where the order will be applied to
  #
  # == Example
  #  class PostsController < ApplicationController
  #    has_order :created_at, only: %i[index]
  #    has_order :creator.last_name, as: :creator, only: %i[index]
  #    has_order_default :'-created_at', only: %i[index]
  #
  #    def index
  #      @posts = apply_orders(Post.all)
  #    end
  #  end
  #
  def apply_orders(target, hash = params)
    return apply_default_order(target) if hash[:sort].blank?

    direction, attribute, nulls = parse_sort_key(hash[:sort])
    options = self.class.order_configurations[attribute]
    return apply_default_order(target) unless options.present? && apply_order_to_action?(options)

    apply_order(target, options[:order], direction, nulls)
  end

  def apply_default_order(target)
    attributes = self.class.order_default

    order_sql = attributes.map { |attribute|
      direction, attribute = parse_sort_key(attribute)

      target, table_attribute = build_table_attribute(target, attribute)

      "#{table_attribute} #{direction}"
    }.join(', ')

    target.order(order_sql)
  end

  def parse_sort_key(sort_key)
    direction, attribute = key_direction(sort_key.to_s)
    nulls = attribute.split(':').second.presence&.to_sym
    attribute = attribute.split(':').first.to_sym

    [direction, attribute, nulls]
  end

  def key_direction(sort_key)
    if sort_key.start_with?('-')
      [:desc, sort_key.delete_prefix('-')]
    elsif sort_key.start_with?('+')
      [:asc, sort_key.delete_prefix('+')]
    else
      [:asc, sort_key]
    end
  end

  def apply_order(target, attribute, direction = :desc, nulls = nil)
    target, table_attribute = build_table_attribute(target, attribute)

    order_sql = "#{table_attribute} #{direction}"

    if nulls.present?
      nulls_sql = nulls == :nulls_first ? 'NULLS FIRST' : 'NULLS LAST'
      order_sql << " #{nulls_sql}"
    end

    target.order(order_sql)
  end

  def build_table_attribute(target, attribute)
    table_name = target.klass.table_name

    if attribute.to_s.include?('.')
      # Parse attribute and association from input
      association, attribute = attribute.to_s.split('.')
      reflection = target.klass.reflect_on_association(association.to_sym)

      # Force join to the target to ensure that the association is joined
      target = target.left_outer_joins(association.to_sym)

      # Pull the table alias from the target in the case where tables are joined multiple times
      table_name = generate_table_alias(target, reflection)
    end

    [target, "#{table_name}.#{attribute}"]
  end

  # Determines the name of the table alias for a given assocation
  #
  # == Example
  # target = Experience.join(:start_common_date, :end_common_date)
  #
  # reflection = Experience.reflect_on_association(:start_common_date)
  # generate_table_alias(target, reflection) #=> "common_dates"
  #
  # reflection = Experience.reflect_on_association(:end_common_date)
  # generate_table_alias(target, reflection) #=> "end_common_dates_experiences"
  #
  def generate_table_alias(target, reflection)
    raise ArguementError, 'association must be has_one or belongs_to' unless reflection.has_one? || reflection.belongs_to?

    # We only support root level joins, so we can assume that the first join is the one we want
    target.arel.source.right.each do |arel_joins|
      # The left side of the join is the base target table
      arel_table = arel_joins.left
      # The right side of the join is the join "on" expression
      arel_on = arel_joins.right

      # Grab the left side of the "on" expression, which is either the table or table alias
      arel_on_table = arel_on.expr.left.relation

      # Pull table name or table alias from the left side of the "on" expression
      table, table_name = case arel_on_table
                          when Arel::Table
                            [arel_table, arel_table.name]
                          when Arel::Nodes::TableAlias
                            [arel_table.left, arel_table.right]
                          end

      # Pull column name to compare against reflection
      column_name = arel_on.expr.right.name

      # Skip if the table or column doesnt match the reflection
      next unless table.name == reflection.table_name && column_name == reflection.foreign_key

      return table_name
    end
  end

  # Determines if sort should be applied to the current action
  def apply_order_to_action?(options)
    return false unless applicable?(options[:if], true) && applicable?(options[:unless], false)

    if options[:only].empty?
      options[:except].empty? || options[:except].exclude?(action_name.to_sym)
    else
      options[:only].include?(action_name.to_sym)
    end
  end

  def applicable?(proc_or_symbol, expected)
    case proc_or_symbol
    when Proc
      string_proc_or_symbol.call(self) == expected
    when Symbol
      send(string_proc_or_symbol) == expected
    else
      true
    end
  end
end

require 'has_scope/railtie' if defined?(Rails)

ActiveSupport.on_load :action_controller do
  include HasOrder
end
