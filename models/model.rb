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

  def to_json(params = {})
    raise(NotImplementedException, "dump() needs to be overridden!")
  end

  # These methods are statically added to the 'model' classes
  module ModelStatic
    def all_to_json(all = all(), params = {})
      # Default to all()
      params[:all] ||= all()

      # Make an array of the json results
      return params[:all].each.to_a().map() { |entry| entry.to_json() }
    end
  end
end
