# model.rb
# Created on November 4, 2014
# By Ron Bowes

require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'

module Model
  def self.included(o)
    o.extend(ModelStatic)
  end

  def to_json(detailed = true)
    raise(NotImplementedException, "dump() needs to be overridden!")
  end

  # These methods are statically added to the 'model' classes
  module ModelStatic
    def all_to_json(all = all(), detailed = false)
      result = []

      all.each do |b|
        result << b.to_json(detailed)
      end

      return result
    end
  end
end
