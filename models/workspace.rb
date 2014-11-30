# workspace.rb
# Created November 4, 2014
# By Ron Bowes

require 'model'
require 'model_properties'

require 'sinatra/activerecord'

class Workspace < ActiveRecord::Base
  include Model
  include ModelProperties

  belongs_to(:binary)
  has_many(:views)
  serialize(:properties, Hash)

  def initialize(params = {})
    params[:properties] ||= {}

    super(params)
  end

  def to_json(params = {})
    return {
      :workspace_id => self.id,
      :binary_id    => self.binary_id,
      :name         => self.name,
      :properties   => self.properties,
    }
  end
end
