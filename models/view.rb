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
      :revision    => 0,
    }))

    @starting_revision = -1
  end

  def next_revision()
    return self.revision + 1
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

        # Save the revision
        segment[:revision] = next_revision()

        # Create the 'special' fields
        segment[:nodes]      = {}
        segment[:nodes_meta] = []
        segment[:xrefs]      = []

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
        if(!node[:refs].nil? && !node[:refs].is_a?(Array))
          raise(ViewException, "The 'refs' field, if specified, must be an array (not a #{node[:refs].class})!")
        end
        if(node[:address] < segment[:address] || (node[:address] + node[:length]) > (segment[:address] + segment[:data].length()))
          raise(ViewException, "The node goes outside the segment's memory space (node goes from 0x%x to 0x%x, segment goes from 0x%x to 0x%x)!" % [
            node[:address],
            node[:address] + node[:length],
            segment[:address],
            segment[:address] + segment[:data].length(),
          ])
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

          # Make sure the metadata table exists without destroying it
          segment[:nodes_meta][address] ||= {}

          # Create some metadata
          segment[:nodes_meta][address][:revision] = next_revision()
        end

        # TODO: This will fail for refs that go outside the segment
        if(node[:refs] && node[:refs].length() > 0)
          node[:refs].each do |ref|
            # Make sure the node has some metadata
            segment[:nodes_meta][ref] ||= {}

            # Make sure the node has an xrefs array
            segment[:nodes_meta][ref][:xrefs] ||= []

            # Save the refs there
            segment[:nodes_meta][ref][:xrefs] << node[:address]
          end
        end

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
    undoable() do |undo|
      # Make sure a segment name was passed in
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

      # Since we're updating the segment, bump up the segment's revision
      segment[:revision] = next_revision()

      # Loop through the addresses we need to delete
      addresses.each do |address|
        # Get the node at that address
        node = segment[:nodes][address]

        # If there wasn't a node there, carry on
        if(node.nil?)
          puts("DEBUG: Tried to delete a nil node")
          next
        end

        # Loop through the actual addresses
        node[:address].upto(node[:address] + node[:length]) do |a|
          # Delete the entry at that address
          segment[:nodes].delete(a)

          # Make sure the metadata exists
          segment[:nodes_meta][a] ||= {}

          # Update the revision
          segment[:nodes_meta][a][:revision] = next_revision()
        end

        # Delete xrefs
        if(node[:refs] && node[:refs].length() > 0)
          node[:refs].each do |ref|
            # Make sure the node has some metadata
            if(segment[:nodes_meta][ref].nil?)
              puts("Warning: missing Xref entry! [1]")
              next
            end

            # Make sure the node has an xrefs array
            if(segment[:nodes_meta][ref][:xrefs].nil?)
              puts("Warning: missing Xref entry! [2]")
              next
            end

            # Delete the xref
            if(segment[:nodes_meta][ref][:xrefs].delete(node[:address]).nil?)
              puts("Warning: missing Xref entry! [3]")
              next
            end

            # Get rid of the xrefs altogether if there aren't any
            if(segment[:nodes_meta][ref][:xrefs].length() == 0)
              segment[:nodes_meta][ref][:xrefs] = nil
            end
          end
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

  # Returns either the real or a fake node (should not be used externally)
  def node_at(segment, address)
    if(segment.nil?)
      raise(ViewException, "segment can't be nil")
    end
    if(!segment.is_a?(Hash))
      raise(ViewException, "segment was the wrong type!")
    end

    if(address.nil?)
      raise(ViewException, "address can't be nil")
    end
    if(!address.is_a?(Fixnum))
      raise(ViewException, "address was the wrong type!")
    end

    # Create either a real node or an undefined one
    if(segment[:nodes][address].nil?)
      value = segment[:data][address].ord()
      if(value >= 0x20 && value < 0x7F)
        value = "<undefined> 0x%02x ; '%c'" % [value, value]
      else
        value = "<undefined> 0x%02x" % value
      end

      node = {
        :type    => "undefined",
        :address => address,
        :length  => 1,
        :value   => value,
        :details => { },
      }
    else
      node = segment[:nodes][address]
    end

    # Add the 'raw' bytes
    node[:raw] = Base64.encode64(segment[:data][address, node[:length]])

    # Get the metadata and add it to the node
    meta = segment[:nodes_meta][address]
    if(!meta.nil?)
      node = node.merge(meta)
    end

    # Ensure we have a revision number (this happens if there is metadata on an undefined node)
    if(node[:revision].nil?)
      node[:revision] = 0
    end

    return node
  end

  def get_nodes(params = {})
    # Possible params (to be done later):
    # start
    # length
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
      node = node_at(segment, address)

      # Sanity checking myself, I can probably remove this later once I trust node_at()
      if(node.nil?)
        raise(ViewException, "Somehow we ended up with node_at() returning nil! Oops!")
      end
      if(node[:revision].nil?)
        raise(ViewException, "Somehow we ended up with node_at() not returning a revision! Oops!")
      end

      # Only add it if it meets the user's requirements
      if(params[:since].nil? || (node[:revision] > params[:since]))
        results << node
      else
        puts("Not including node with revision %d (showing nodes since %d)" % [node[:revision], params[:since]])
      end

      address += node[:length]
    end

    return results
  end

  def to_json(params = {})
    # Make sure these are true-ish
    with_segments = params[:with_segments]
    with_nodes    = params[:with_nodes]
    with_data     = params[:with_data]
    since         = params[:since] || -1

    result = {
      :name     => self.name,
      :view_id  => self.id,
      :revision => self.revision,
    }

    # Ensure the names argument is always an array
    if(params[:names] == '')
      params[:names] = nil
    elsif(params[:names] && params[:names].is_a?(String))
      params[:names] = [params[:names]]
    end

    if(with_segments)
      result[:segments] = {}

      self.segments.each_value do |segment|
        # If the user wanted a specific segment name
        if(!params[:names].nil? && !params[:names].include?(segment[:name]))
          next
        end

        # If we're looking for anything updated since a certain point, skip older stuff
        if(segment[:revision] <= since)
          next
        end

        # The entry for this segment
        s = {
          :name     => segment[:name],
          :revision => segment[:revision],
        }

        # Don't include the data if the requester doesn't want it
        if(with_data == true)
          s[:data] = Base64.encode64(segment[:data])
        end

        # Let the user skip including nodes
        if(with_nodes)
          s[:nodes] = get_nodes(params.merge({:segment_name => segment[:name]}))
        end

        result[:segments][s[:name]] = s
      end
    end

    return result
  end

  after_find do |c|
    # Set up the starting revision
    @starting_revision = self.revision
  end

  after_create do |c|
    @starting_revision = self.revision # Should be 0
  end

  before_save do
    self.revision += 1
  end
end
