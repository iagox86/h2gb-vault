# workspace.rb
# By Ron Bowes
# Created October 6, 2014

require 'model'
require 'model_properties'

require 'json'
require 'sinatra/activerecord'
require 'logger'

class WorkspaceException < StandardError
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
      raise(WorkspaceException, "record_action requires a :forward parameter!")
    end

    backward = params[:backward]
    if(backward.nil?)
      raise(WorkspaceException, "record_action requires a :backward parameter!")
    end

    if(@undoing)
      # If we're redo-ing, add to the redo buffer backwards
      self.redo_buffer << { :type => :method, :forward => backward, :backward => forward }
    else
      self.undo_buffer << { :type => :method, :forward => forward, :backward => backward }

      # When a real action is taken, kill the 'redo' buffer
      if(!@redoing)
        self.redo_buffer.clear()
      end
    end
  end

  def undo(params = {})
    @undoing = true

    # Create a checkpoint in the redo buffer
    self.redo_buffer << { :type => :checkpoint }

    loop do
      action = self.undo_buffer.pop()
      if(action.nil?)
        logger.warn("undo(nil) # exiting redo")
        break
      end
      logger.warn("undo(#{action[:backward].inspect})")

      if(action[:type] == :checkpoint)
        break
      elsif(action[:type] == :method)
        self.send(action[:backward][:method], action[:backward][:params])
      else
        raise(WorkspaceException, "Unknown action type: #{action[:type]}")
      end

      if(params[:step] == true)
        break
      end
    end


    @undoing = false
  end

  def redo(params = {})
    @redoing = true

    loop do
      action = self.redo_buffer.pop()
      if(action.nil?)
        logger.warn("redo(nil) # exiting redo")
        break
      end

      logger.warn("redo(#{action[:forward].inspect})")

      if(action[:type] == :checkpoint)
        break
      elsif(action[:type] == :method)
        self.send(action[:forward][:method], action[:forward][:params])
      else
        raise(WorkspaceException, "Unknown action type: #{action[:type]}")
      end

      if(params[:step] == true)
        break
      end
    end

    @redoing = false
  end

  def undo_to_json(params = {})
    return {
      :undo => self.undo_buffer,
      :redo => self.redo_buffer,
    }
  end

  def clear_undo_log()
    self.undo_buffer.clear()
    self.redo_buffer.clear()
  end
end

module Refs
  def sanity_check_refs(refs)
    # If it's not present, just ignore it
    if(refs.nil?)
      return false
    end

    # If it's not an array, that's a bigger problem
    if(!refs.is_a?(Array))
      raise(WorkspaceException, "The 'refs' field needs to either be nil or an array")
    end

    # Make sure each ref is a hash containing an :address
    refs.each do |ref|
      if(!ref.is_a?(Hash))
        raise(WorkspaceException, "Each element in the 'refs' array needs to be a Hash")
      end
      if(ref[:address].nil?)
        raise(WorkspaceException, "Each element in the 'refs' array needs to have an :address field")
      end
    end

    return true
  end

  def create_ref(from_segment, from_address, tos)
    logger.warn("create_ref(#{from_segment}, #{from_address}, #{tos})")
    self.refs[from_segment] ||= {}
    self.refs[from_segment][from_address] ||= []

    tos.each do |to|
      # Safe the forward reference
      self.refs[from_segment][from_address] << to.clone

      # Save the cross reference (note: we have to clone this, otherwise we screw up the original object)
      xref = to.clone
      to_address = xref.delete(:address)
      self.xrefs[to_address] ||= [] # TODO: This is kind of a fugly way of storing / deleting xrefs
      self.xrefs[to_address] << {
        :segment => from_segment,
        :address => from_address
      }.merge(xref)

      each_segment_at(to_address) do |name, segment|
        segment[:revision] = next_revision()

        segment[:nodes_meta][to_address] ||= {}
        segment[:nodes_meta][to_address][:revision] = next_revision()
      end
    end
  end

  def delete_ref(from_segment, from_address)
    logger.warn("delete_ref(#{from_segment}, #{from_address})")

    tos = self.refs[from_segment].delete(from_address) || []

    tos.each do |to|
      to_address = to[:address]

      # Delete the appropriate elements
      self.xrefs[to_address].delete_if do |element|
        (element[:segment] == from_segment && element[:address] == from_address)
      end

      # Update the revision metadata
      each_segment_at(to_address) do |name, segment|
        segment[:revision] = next_revision()
        segment[:nodes_meta][to_address] ||= {}
        segment[:nodes_meta][to_address][:revision] = next_revision()
      end
    end
  end

  def get_refs(from_segment, from_address)
    if(!self.refs[from_segment].nil?)
      return self.refs[from_segment][from_address] || []
    end
    return []
  end

  def get_xrefs(to_address, to_length)
    result = []

    to_address.upto(to_address + to_length - 1) do |to_addr|
      result += (self.xrefs[to_addr] || [])
    end

    return result.sort { |x,y| x[:address] <=> y[:address] }
  end
end

class MarshallData
  def self.load(str)
    if(str.nil?)
      return nil
    end
    return Marshal::load(str)
  end
  def self.dump(obj)
    return Marshal::dump(obj)
  end
end

class Workspace < ActiveRecord::Base
  include Model
  include ModelProperties
  include Undoable
  include Refs

  belongs_to(:binary)

  serialize(:properties,  Hash)
  serialize(:undo_buffer, Array)
  serialize(:redo_buffer, Array)
  serialize(:segments,    MarshallData)
  serialize(:refs,        Hash)
  serialize(:xrefs,       Hash)

  attr_reader :starting_revision

  def initialize(params = {})
    params[:properties] ||= {}

    super(params.merge({
      :properties  => {},
      :undo_buffer => [],
      :redo_buffer => [],
      :segments    => {},
      :refs        => {},
      :xrefs       => {},
      :revision    => 0,
    }))

    @starting_revision = -1
  end

  def next_revision()
    return self.revision + 1
  end

  def each_segment_at(address)
    self.segments.each_pair do |name, segment|
      if(address >= segment[:address] && address < segment[:address] + segment[:data].length)
        yield(name, segment)
      end
    end
  end

  def create_segments(segments)
    undoable() do |undo|
      # Force segments into an array
      if(!segments.is_a?(Array))
        raise(WorkspaceException, "The 'segments' field has to be an array")
      end

      segments.each do |segment|
        logger.warn("create_segment(#{segment.inspect})")
        # Do some sanity checks
        if(segment[:address].nil?)
          raise(WorkspaceException, "The 'name' field is required when creating a segment")
        end

        if(!self.segments[segment[:name]].nil?)
          raise(WorkspaceException, "A segment with the name #{segment[:name]} already exists!")
        end

        if(segment[:address].nil?)
          raise(WorkspaceException, "The 'address' field is required when creating a segment")
        end
        if(segment[:data].nil?)
          raise(WorkspaceException, "The 'data' field is required when creating a segment")
        end

        # Save the revision
        segment[:revision] = next_revision()

        # Save the initial revision
        segment[:start_revision] = next_revision()

        # Create the 'special' fields
        segment[:nodes]      = {}
        segment[:nodes_meta] = {}

        # Store the new segment
        self.segments[segment[:name]] = segment

        # Make a note of it for the undo buffer
        undo.record_action(
          :forward => {
            :type   => :method,
            :method => :create_segments,
            :params => [segment],
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
#        if(name.is_a?(Symbol))
#          name = name.to_s
#        end

        logger.warn("delete_segment(#{name.inspect})")
        segment = self.segments[name]
        if(segment.nil?)
          raise(WorkspaceException, "A segment with the name '#{name}':#{name.class} could not be found! Known segments: #{self.segments.keys.join(", ")}")
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
            :params => [segment],
          }
        )
      end
    end
  end

  def delete_all_segments()
    # Do this workspace delete_segments so we get undo for free
    delete_segments(self.segments.keys)
  end

  def create_nodes(params)
    undoable() do |undo|
      # Make sure a segment name was passed in
      segment_name = params[:segment_name]
      if(segment_name.nil?)
        raise(WorkspaceException, ":segment_name is required")
      end

      # Get the segment and make sure it exists
      segment = self.segments[segment_name]
      if(segment.nil?)
        raise(WorkspaceException, "A segment with the name '#{segment_name}':#{segment_name.class} could not be found! Known segments: #{self.segments.keys.join(", ")}")
      end

      # Make sure the nodes were pased
      nodes = params[:nodes]
      if(nodes.nil?)
        raise(WorkspaceException, ":nodes is required")
      end

      # Force nodes into being an array TODO: Create a method for this
      if(!nodes.is_a?(Array))
        nodes = [nodes]
      end

      # Loop through the nodes
      nodes.each do |node|
        logger.warn("create_node(#{segment_name}, #{node.inspect})")
        # Sanity checks
        if(node[:type].nil?)
          raise(WorkspaceException, "The 'type' field is required!")
        end
        if(node[:address].nil?)
          raise(WorkspaceException, "The 'address' field is required!")
        end
        if(node[:length].nil?)
          raise(WorkspaceException, "The 'length' field is required!")
        end
        if(node[:value].nil?)
          raise(WorkspaceException, "The 'value' field is required!")
        end
        if(!node[:refs].nil? && !node[:refs].is_a?(Array))
          raise(WorkspaceException, "The 'refs' field, if specified, must be an array (not a #{node[:refs].class})!")
        end

        if(node[:address] < segment[:address] || (node[:address] + node[:length]) > (segment[:address] + segment[:data].length()))
          raise(WorkspaceException, "The node goes outside the segment's memory space (node goes from 0x%x to 0x%x, segment goes from 0x%x to 0x%x)!" % [
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

        # Save the refs (and implicitly create xrefs)
        if(sanity_check_refs(node[:refs]))
          create_ref(segment_name, node[:address], node[:refs])
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
            :nodes        => nodes,
          },
        },
        :backward => {
          :type   => :method,
          :method => :delete_nodes,
          :params => {
            :segment_name => segment_name,
            :addresses    => nodes.map() { |node| node[:address] }
          },
        }
      )
    end
  end

  def delete_nodes(params)
    undoable() do |undo|
      # Make sure a segment name was passed in
      segment_name = params[:segment_name]
      if(segment_name.nil?)
        raise(WorkspaceException, ":segment_name is required")
      end

      # Get the segment and make sure it exists
      segment = self.segments[segment_name]
      if(segment.nil?)
        raise(WorkspaceException, "A segment with the name '#{segment_name}':#{segment_name.class} could not be found! Known segments: #{self.segments.keys.join(", ")}")
      end

      addresses = params[:addresses]
      if(addresses.nil?)
        raise(WorkspaceException, ":addresses is a required field")
      end
      if(!addresses.is_a?(Array))
        addresses = [addresses]
      end

      # Since we're updating the segment, bump up the segment's revision
      segment[:revision] = next_revision()

      # Loop through the addresses we need to delete
      addresses.each do |address|
        logger.warn("delete_node(%s, 0x%08x)" % [segment_name, address])

        # Get the node at that address
        node = segment[:nodes][address]

        # If there wasn't a node there, carry on
        if(node.nil?)
          next
        end

        # Loop through the actual addresses
        node[:address].upto(node[:address] + node[:length] - 1) do |a|
          # Delete the entry at that address
          segment[:nodes].delete(a)

          # Make sure the metadata exists
          segment[:nodes_meta][a] ||= {}

          # Update the revision
          segment[:nodes_meta][a][:revision] = next_revision()
        end

        # Delete refs
        delete_ref(segment_name, node[:address])

        # Record the action
        undo.record_action(
          :forward => {
            :type   => :method,
            :method => :delete_nodes,
            :params => {
              :segment_name => segment_name,
              :addresses    => address,
            },
          },
          :backward => {
            :type   => :method,
            :method => :create_nodes,
            :params => {
              :segment_name => segment_name,
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
      raise(WorkspaceException, "segment can't be nil")
    end
    if(!segment.is_a?(Hash))
      raise(WorkspaceException, "segment was the wrong type!")
    end

    if(address.nil?)
      raise(WorkspaceException, "address can't be nil")
    end
    if(!address.is_a?(Fixnum))
      raise(WorkspaceException, "address was the wrong type!")
    end

    # Get the offset into the node so we can handle the data properly
    offset = address - segment[:address]

    if(offset < 0)
      raise(WorkspaceException, "address was too small for the segment")
    end
    if(offset >= segment[:data].length)
      raise(WorkspaceException, "address was too big for the segment")
    end

    # Create either a real node or an undefined one
    if(segment[:nodes][address].nil?)
      value = segment[:data][offset].ord()
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
        :details => {},
      }
    else
      node = segment[:nodes][address]
    end

    # Add the 'raw' bytes
    node[:raw] = Base64.encode64(segment[:data][offset, node[:length]])

    # Figure out some meta-data based on any nodes
    node[:refs] = get_refs(segment[:name], node[:address])
    node[:xrefs] = get_xrefs(node[:address], node[:length])
    node[:revision] = segment[:start_revision] # Safe default

    node[:address].upto(node[:address] + node[:length] - 1) do |a|
      # Make sure we have some metadata
      if(!segment[:nodes_meta][a].nil?)
        # Take the most recent revision of any nodes
        revision = segment[:nodes_meta][a][:revision]
        if(!revision.nil? && revision > node[:revision])
          node[:revision] = revision
        end
      end
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
      raise(WorkspaceException, ":segment_name is required")
    end

    # Get the segment and make sure it exists
    segment = self.segments[segment_name]
    if(segment.nil?)
      raise(WorkspaceException, "A segment with the name '#{segment[:name]}':#{segment[:name].class} could not be found! Known segments: #{self.segments.keys.join(", ")}")
    end

    results = {}
    address = segment[:address]
    while(address < segment[:address] + segment[:data].length) do
      node = node_at(segment, address)

      # Sanity checking myself, I can probably remove this later once I trust node_at()
      if(node.nil?)
        raise(WorkspaceException, "Somehow we ended up with node_at() returning nil! Oops!")
      end
      if(node[:revision].nil?)
        raise(WorkspaceException, "Somehow we ended up with node_at() not returning a revision! Oops!")
      end

      # Only add it if it meets the user's requirements
      if(params[:since].nil? || (node[:revision] > params[:since]))
        results[node[:address]] = node
      else
        #puts("Not including node with revision %d (showing nodes since %d)" % [node[:revision], params[:since]])
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
      :workspace_id => self.id,
      :binary_id    => binary.id,
      :name         => self.name,
      :revision     => self.revision,
      :properties   => self.properties,
    }

    # Ensure the names argument is always an array
    if(params[:names] == '')
      params[:names] = nil
    elsif(params[:names] && params[:names].is_a?(String))
      params[:names] = [params[:names]]
    end

    if(with_segments)
      result[:segments] = []

      self.segments.each_pair do |name, segment|
        # If the user wanted a specific segment name
        if(!params[:names].nil? && !params[:names].include?(segment[:name].to_s))
          next
        end

        # If we're looking for anything updated since a certain point, skip older stuff
        if(segment[:revision] <= since)
          next
        end

        # The entry for this segment
        s = {
          :name         => segment[:name],
          :revision     => segment[:revision],
          :address      => segment[:address],
          :details      => segment[:details],
        }

        # Don't include the data if the requester doesn't want it
        if(with_data == true)
          s[:data] = Base64.encode64(segment[:data])
        end

        # Let the user skip including nodes
        if(with_nodes)
          s[:nodes] = get_nodes(params.merge({:segment_name => name}))
        end

        result[:segments] << s
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
