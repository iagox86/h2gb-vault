$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'

require 'formats/elf'
require 'formats/pe'
require 'formats/raw'

require 'arch/x86'
require 'arch/x64'

# Debug
require 'pp'

# Types:
#   'unknown'
#     length
#     data
#     section
#     xrefs

class Project < ActiveRecord::Base
  # Tell ActiveRecord to serialize the instructions field
  self.serialize(:view, Hash)

  self.belongs_to(:binary)
  self.has_many(:deltas)

  def initialize(params)
    if(params[:view])
      # TODO: This will be used when we're building on another view
      raise NotImplementedError
    else
      b = params[:binary]

      view = {}
      b.each_byte do |section, addr, data|
        view[addr] = {
          :type => "unknown",
          :data => data,
          :length => 1
        }
      end
      params[:view] = view
    end

    super(params)
  end

  def apply_delta(view, delta)
    if(delta[:type] == "change_type")
      # TODO
    end
  end

  def get_current_view()
    puts()
    deltas = self.deltas
    puts()

    view = self.view

    deltas.each do |delta|
      delta.deltas.each do |d|
        apply_delta(view, d)
      end
    end

    exit
  end

  def save_checkpoint()
    raise NotImplementedError
  end
end
