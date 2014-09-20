require 'sinatra'
require 'sinatra/activerecord'

class Binary < ActiveRecord::Base
  self.primary_key = :id
end

