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
    raise(NotImplementedError, "to_json() needs to be overridden!")
  end

  def as_json(p = {})
    raise(Exception, "You probably want to use to_json().")
  end

  # These methods are statically added to the 'model' classes
  module ModelStatic
    def all_to_json(params = {})
      # Make an array of the json results
      return (params[:all] || all()).map() { |entry| entry.to_json(params) }
    end
  end
end
