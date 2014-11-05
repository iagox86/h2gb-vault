# model.rb
# Created on November 4, 2014
# By Ron Bowes

require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'

module Model
  def to_json(detailed = false)
    raise(NotImplementedException, "dump() needs to be overridden!")
  end
end
