# view.rb
# By Ron Bowes
# Created October 6, 2014

$LOAD_PATH << File.dirname(__FILE__)

require 'model.rb'

require 'json'
require 'sinatra/activerecord'

require 'pp' # TODO: Debug

if(ARGV[0] == "testview")
  ActiveRecord::Base.establish_connection(
    :adapter => 'sqlite3',
    :host    => nil,
    :username => nil,
    :password => nil,
    :database => 'data.db',
    :encoding => 'utf8',
  )
end

class ViewException < StandardError
end

module Undoable
  attr_reader :undoing

  def self.included(obj)
    @undoing     = false
    @in_undoable = false
  end

  def undoable()
    if(@in_undoable)
      yield(self)
    else
      @in_undoable = true

      if(!@undoing)
        self.undo_buffer << { :type => :checkpoint }
      end

      yield(self)

      @in_undoable = false
    end
  end

  def record_action(params = {})
    forward = params[:forward]
    if(forward.nil?)
      raise(ViewException, "record_action requires a :forward parameter!")
    end

    backward = params[:backward]
    if(backward.nil?)
      raise(ViewException, "record_action requires a :backward parameter!")
    end

    if(!@undoing)
      self.undo_buffer << { :type => :method, :forward => forward, :backward => backward }

      # When a real action is taken, kill the 'redo' buffer
      if(!@redoing)
        self.redo_buffer = []
      end
    else
      # If we're redo-ing, add to the redo buffer
      self.redo_buffer << { :type => :method, :forward => forward, :backward => backward }
    end
  end

  def undo()
    @undoing = true

    puts("Entering undo()!")

    loop do
      action = self.undo_buffer.pop()
      if(action.nil?)
        puts("DEBUG: No more actions left in the undo buffer")
        break
      end

      if(action[:type] == :checkpoint)
        puts("CHECKPOINT!")
        break
      elsif(action[:type] == :method)
        puts("UNDOING:")
        pp(action)
        self.send(action[:backward][:method], action[:backward][:params])
      else
        raise(ViewException, "Unknown action type: #{action[:type]}")
      end
    end

    @undoing = false
  end

  def redo()
    puts("Entering redo()!")
    @redoing = true

    loop do
      action = self.redo_buffer.pop()
      if(action.nil?)
        puts("DEBUG: No more actions left in the redo buffer")
        break
      end

      if(action[:type] == :checkpoint)
        puts("CHECKPOINT!")
        break
      elsif(action[:type] == :method)
        puts("REDOING:")
        self.send(action[:backward][:method], action[:backward][:params])
      else
        raise(ViewException, "Unknown action type: #{action[:type]}")
      end

      break # TODO: Figure out how to add checkpoints to redo properly
    end

    @redoing = false
  end
end

class View < ActiveRecord::Base
  include Model
  include Undoable

  belongs_to(:workspace)

  serialize(:undo_buffer)
  serialize(:redo_buffer)
  serialize(:segments)

  attr_reader :starting_revision

  def initialize(params = {})
    super(params.merge({
      :undo_buffer => [],
      :redo_buffer => [],
      :segments    => {},
    }))

    @starting_revision = 0
  end

  def revision()
#    self.rev += 1
#
#    return self.rev
  end

  def create_segments(segments)
    undoable() do |undo|
      # Force segments into an array
      if(!segments.is_a?(Array))
        segments = [segments]
      end

      segments.each do |segment|
        # Do some sanity checks
        if(segment[:name].nil?)
          raise(ViewException, "The 'name' field is required when creating a segment")
        end
        if(!self.segments[segment[:name]].nil?)
          raise(ViewException, "A segment with that name already exists!")
        end
        if(segment[:address].nil?)
          raise(ViewException, "The 'address' field is required when creating a segment")
        end
        if(segment[:data].nil?)
          raise(ViewException, "The 'data' field is required when creating a segment")
        end

        # Decode the base64
        segment[:data] = Base64.decode64(segment[:data])

        # Create the 'special' fields
#        segment[:revision] = revision()
        segment[:nodes]    = {}
        segment[:xrefs]    = []

        # Store the new segment
        self.segments[segment[:name]] = segment

        # Make a note of it for the undo buffer
        undo.record_action(
          :forward => {
            :type   => :method,
            :method => :create_segments,
            :params => segment,
          },
          :backward => {
            :type   => :method,
            :method => :delete_segments,
            :params => segment[:name],
          }
        )
      end
    end
  end

  def delete_segments(names)
    puts(self.segments.inspect)

    undoable() do |undo|
      # Force names into being an array
      if(!names.is_a?(Array))
        names = [names]
      end

      names.each do |name|
        segment = self.segments[name]
        if(segment.nil?)
          raise(ViewException, "A segment with that name could not be found!")
        end

        # Make sure it doesn't have any nodes
        # TODO: This probably isn't very efficient
        delete_nodes(
          :segment_name => name,
          :addresses    => ((segment[:address])..(segment[:address]+segment[:data].length()-1)).to_a(),
        )

        # Do the actual delete
        self.segments.delete(name)

        # Record the action (note: this needs to go after delete_nodes(), otherwise things will
        # undo in the wrong order...
        undo.record_action(
          :forward => {
            :type   => :method,
            :method => :delete_segments,
            :params => name,
          },
          :backward => {
            :type   => :method,
            :method => :create_segments,
            :params => segment,
          }
        )
      end
    end
  end

  def create_nodes(params)
    undoable() do |undo|
      # Make sure a segment name was passed in
      segment_name = params[:segment_name]
      if(segment_name.nil?)
        raise(ViewException, ":segment_name is required")
      end

      # Get the segment and make sure it exists
      segment = self.segments[segment_name]
      if(segment.nil?)
        raise(ViewException, "A segment with that name could not be found!")
      end

      # Make sure the nodes were pased
      nodes = params[:nodes]
      if(nodes.nil?)
        raise(ViewException, ":nodes is required")
      end

      # Force nodes into being an array TODO: Create a method for this
      if(!nodes.is_a?(Array))
        nodes = [nodes]
      end

      # Loop through the nodes
      nodes.each do |node|
        # Sanity checks
        if(node[:type].nil?)
          raise(ViewException, "The 'type' field is required!")
        end
        if(node[:address].nil?)
          raise(ViewException, "The 'address' field is required!")
        end
        if(node[:length].nil?)
          raise(ViewException, "The 'length' field is required!")
        end
        if(node[:value].nil?)
          raise(ViewException, "The 'value' field is required!")
        end

        # Loop through all the addresses in the node
        ((node[:address])..(node[:address]+node[:length]-1)).each do |address|
          # Make sure the memory we're gonna use is undefined
          delete_nodes(
            :segment_name => segment_name,
            :addresses    => address
          )

          # Create the node
          segment[:nodes][address] = node
        end

        # TODO: Record Xrefs

        # TODO: Sanity check the address

        # Record the action (note: this needs to go after delete_nodes(), otherwise things will
        # undo in the wrong order...
        undo.record_action(
          :forward => {
            :type   => :method,
            :method => :create_nodes,
            :params => {
              :segment_name => segment_name,
              :nodes        => node,
            },
          },
          :backward => {
            :type   => :method,
            :method => :delete_nodes,
            :params => {
              :segment_name => segment_name,
              :addresses    => node[:address],
            },
          }
        )
      end
    end
  end

  def delete_nodes(params)
    puts("in delete_nodes(#{params.inspect})")

    undoable() do |undo|
      # Make sure a segment name was passed in
      puts(params.inspect)
      segment_name = params[:segment_name]
      if(segment_name.nil?)
        raise(ViewException, ":segment_name is required")
      end

      # Get the segment and make sure it exists
      segment = self.segments[segment_name]
      if(segment.nil?)
        raise(ViewException, "A segment with the name '#{segment_name}' could not be found! Known segments: #{self.segments.keys.join(", ")}")
      end

      addresses = params[:addresses]
      if(addresses.nil?)
        raise(ViewException, ":addresses is a required field")
      end
      if(!addresses.is_a?(Array))
        addresses = [addresses]
      end

      # Loop through the addresses we need to delete
      addresses.each do |address|
        # Get the node at that address
        node = segment[:nodes][address]

        # If there wasn't a node there, carry on
        if(node.nil?)
          puts("DEBUG: Tried to delete a nil node")
          next
        end

        node[:address].upto(node[:address] + node[:length]) do |a|
          segment[:nodes].delete(a)
        end

        # Record the action
        undo.record_action(
          :forward => {
            :type   => :method,
            :method => :delete_nodes,
            :params => {
              :segment_name => segment[:name],
              :addresses    => address,
            },
          },
          :backward => {
            :type   => :method,
            :method => :create_nodes,
            :params => {
              :segment_name => segment[:name],
              :nodes        => node,
            },
          }
        )
      end
    end
  end

  def get_nodes_in_segment(params = {})
    # Possible params (to be done later):
    # start
    # length
    # revision
    # hide_undefined

    # Make sure a segment name was passed in
    segment_name = params[:segment_name]
    if(segment_name.nil?)
      raise(ViewException, ":segment_name is required")
    end

    # Get the segment and make sure it exists
    segment = self.segments[segment_name]
    if(segment.nil?)
      raise(ViewException, "A segment with that name could not be found!")
    end

    results = []
    address = segment[:address]
    while(address < segment[:address] + segment[:data].length) do
      node = segment[:nodes][address]

      if(!node.nil?)
        results << node.merge({
          :raw => Base64.encode64(segment[:data][address, node[:length]]),
        })

        address += node[:length]
        # TODO: Include the 'raw' data
      else
        # Make fake node
        value = segment[:data][address].ord()
        if(value >= 0x20 && value < 0x7F)
          value = "<undefined> 0x%02x ; '%c'" % [value, value]
        else
          value = "<undefined> 0x%02x" % value
        end

        results << {
          :type    => "undefined",
          :address => address,
          :length  => 1,
          :value   => value,
          :details => { },
          :raw     => Base64.encode64(segment[:data][address, 1]),
        }
        address += 1
      end
    end

    return results
  end

  def to_json(params = {})
#    starting = (params[:starting] || 0).to_i()
    with_nodes = (params[:with_nodes] == "true")
    with_data  = (params[:with_data]  == "true")

    result = {
      :name     => self.name,
      :view_id  => self.id,
      :revision => self.revision(),
      :segments => [],
    }

    # Ensure the names argument is always an array
    if(params[:names] == '')
      params[:names] = nil
    elsif(params[:names] && params[:names].is_a?(String))
      params[:names] = [params[:names]]
    end

    # I want all segments, because it's possible that a node inside a segment matters
    # TODO: When I update a node, also update the segment's revision
    self.segments.each_value do |segment|
      # If the user wanted a specific segment name
      if(!params[:names].nil? && !params[:names].include?(segment[:name]))
        next
      end

      # The entry for this segment
      s = {
        :name => segment[:name],
#        :revision => segment[:revision]
      }

      # Don't include the data if the requester doesn't want it
      if(with_data == true)
        s[:data] = Base64.encode64(segment[:data])
      end

      # Let the user skip including nodes
      if(with_nodes == true)
        s[:nodes] = get_nodes_in_segment(:segment_name => segment[:name])
      end

      # Check if this segment should be included
#      if((!s[:nodes].nil? && s[:nodes].length > 0) || s[:revision] >= starting)
        result[:segments] << s
#      end
    end

    return result
  end

  after_find do |c|
    # Initialize the objects we need
#    init()

    # Set up the starting revision
#    @starting_revision = revision()
  end

  after_create do |c|
    # Initialize the objects we need
#    init()
  end
end
