$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'models/binary'
require 'models/view'
require 'models/workspace'

require 'json'

require 'pp' # TODO: DEBUG

# Disable verbose logging

# Database stuff
ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :host    => nil,
  :username => nil,
  :password => nil,
  :database => 'data.db',
  :encoding => 'utf8',
)

class VaultException < StandardError
end

class Vault < Sinatra::Application
  set :environment, :production

  def add_status(status, table)
    table[:status] = status
    return table
  end

  def to_a(d)
    if(d.is_a?(Array))
      return d
    end
    return [d]
  end

  def convert_num(n)
    if(n > 0xFFFF)
      return '0x%08x' % n
    elsif(n > 0xFF)
      return '0x%04x' % n
    elsif(n > 0)
      return '0x%02x' % n
    elsif(n == 0)
      return '0'
    else
      return "-%s" % (convert_num(n.abs()))
    end
  end

  def nested_elements(h)
    if(h.is_a?(Hash))
      h.each do |k, v|
        if(v.is_a?(Hash) || v.is_a?(Array))
          nested_elements(v) do |val|
            yield(val)
          end
        else
          h[k] = yield(v)
        end
      end
    elsif(h.is_a?(Array))
      h.each_index do |k|
        v = h[k]
        if(v.is_a?(Hash) || v.is_a?(Array))
          nested_elements(v) do |val|
            yield(val)
          end
        else
          h[k] = yield(v)
        end
      end
    end
  end

  before do
    # Turn down the logging
    ActiveRecord::Base.logger.sev_threshold = Logger::WARN
  end

  before do
    # Do an ugly check to see if we're using a version of Sinatra that doesn't expose the params
    begin
      if(params.nil?)
        raise(VaultException, "Control-flow exceptions are bad")
      end
    rescue
      raise(VaultException, "It looks like there's a problem in the before() function, updating Sinatra will likely fix it")
    end

    # Truthify the parameters
    result = {}
    params.each_pair do |k, v|
      if(v == '')
        v = nil
      elsif(v == 'true')
        v = true
      elsif(v == 'false')
        v = false
      elsif(v =~ /^[0-9]+$/)
        v = v.to_i()
      end

      result[k.to_sym] = v
    end

    # Clear out all other parameters
    params.clear()

    # Merge in the fixed ones
    params.merge!(result)

    # Merge in body parameters if they're present
    if(request.body.present?)
      body = request.body.read()

      if(body.length > 0)
        params.merge!(JSON.parse(body, :symbolize_names => true))
      end
    end
  end

  # Add important headers and encode everything as JSON
  after do
    if(response.content_type.nil?)
      content_type 'application/json'
    end

    headers({ 'X-Frame-Options' => 'DENY' })

    if(response.content_type =~ /json/)
      headers({
        'Access-Control-Allow-Origin' => '*', # TODO: Might not need this forever
        'Content-Disposition' => 'Attachment'
      })

      nested_elements(response.body) do |e|
        value = e

        if(params['force_text'] && e.is_a?(Fixnum))
          value = ('0x%x' % e)
        elsif(e.is_a?(String))
          value = e.force_encoding('ISO-8859-1')
        end

        value # return
      end

      if(params['pretty'])
        response.body = JSON.pretty_generate(response.body) + "\n"
      else
        response.body = JSON.generate(response.body) + "\n"
      end

    end
  end

  # Handle errors (exceptions and stuff)
  error do
    status 500

    return add_status(500,  {:reason => env['sinatra.error'] })
  end

  # Handle file-not-found errors
  not_found do
    status 404

    return add_status(404, {:reason => 'not found' })
  end

  get('/') do
    return "Welcome to h2gb! If you don't know what to do, you probably don't need to be here. :)"
  end

  post('/binaries') do
    b = Binary.new(
      :name         => params.delete(:name),
      :comment      => params.delete(:comment),
      :data         => Base64.decode64(params.delete(:data)),
    )
    b.save()

    return b.to_json(params)
  end

  get('/binaries') do
    return {:binaries => Binary.all_to_json(params) }
  end

  get('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    return b.to_json(params)
  end

  put('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    if(!params[:name].nil?)
      b.name = params.delete(:name)
    end

    if(!params[:comment].nil?)
      b.comment = params.delete(:comment)
    end

    if(!params[:data].nil?)
      b.data = Base64.decode64(params.delete(:data))
    end
    b.save()

    return b.to_json(params)
  end

  delete('/binaries/:binary_id') do |binary_id|
    b = Binary.find(binary_id)
    b.destroy()

    return {:deleted => true}
  end

  post('/binaries/:binary_id/set_properties') do |binary_id|
    b = Binary.find(binary_id)

    properties = params.delete(:properties)
    if(!properties.is_a?(Hash))
      raise(VaultException, "The :properties parameter is mandatory, and must be a hash")
    end

    b.set_properties(properties)
    b.save()

    return b.to_json(params)
  end

  post('/binaries/:binary_id/get_properties') do |binary_id|
    b = Binary.find(binary_id)
    keys = params.delete(:keys)
    result = b.get_properties(keys)
    return result
  end

  post('/binaries/:binary_id/new_workspace') do |binary_id|
    b = Binary.find(binary_id)
    w = b.workspaces.new(:name => params.delete(:name))
    w.save()

    return w.to_json(params)
  end

  get('/binaries/:binary_id/workspaces') do |binary_id|
    b = Binary.find(binary_id)

    return {:workspaces => Workspace.all_to_json(:all => b.workspaces.all()) }
  end

  # Get info about a workspace
  get('/workspaces/:workspace_id') do |workspace_id|
    w = Workspace.find(workspace_id)

    return w.to_json(params)
  end

  # Update workspace
  put('/workspaces/:workspace_id') do |workspace_id|
    w = Workspace.find(workspace_id)
    w.name = params.delete(:name)
    w.save()

    return w.to_json(params)
  end

  delete('/workspaces/:workspace_id') do |workspace_id|
    w = Workspace.find(workspace_id)
    w.destroy()

    return {:deleted => true}
  end

  post('/workspaces/:workspace_id/set_properties') do |workspace_id|
    w = Workspace.find(workspace_id)

    properties = params.delete(:properties)
    if(!properties.is_a?(Hash))
      raise(VaultException, "The :properties parameter is mandatory, and must be a hash")
    end

    w.set_properties(properties)
    w.save()

    return w.to_json(params)
  end

  post('/workspaces/:workspace_id/get_properties') do |workspace_id|
    w = Workspace.find(workspace_id)
    keys = params.delete(:keys)
    result = w.get_properties(keys)
    return result
  end

  # Create view
  post('/workspaces/:workspace_id/new_view') do |workspace_id|
    w = Workspace.find(workspace_id)

    view = w.views.new(:name => params.delete(:name))
    view.save()
    return view.to_json(params)
  end

  # Get views for a workspace
  get('/workspaces/:workspace_id/views') do |workspace_id|
    w = Workspace.find(workspace_id)

    return {
      :views => View.all_to_json({
        :all => w.views.all()
      }.merge(params)
    )}
  end

  # Find view
  get('/views/:view_id') do |view_id|
    v = View.find(view_id)

    return v.to_json({
      :with_segments => false, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
    }.merge(params))
  end

  # Update view
  # TODO: Make sure this is being tested
  put('/views/:view_id') do |view_id|
    v = View.find(view_id)
    v.name = params[:name]
    v.save()

    return v.to_json({
      :with_segments => false, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
    }.merge(params))
  end

  # Delete view
  delete('/views/:view_id') do |view_id|
    v = View.find(view_id)
    v.destroy()

    return {:deleted => true}
  end

  post('/views/:view_id/set_properties') do |view_id|
    v = View.find(view_id)

    properties = params.delete(:properties)
    if(!properties.is_a?(Hash))
      raise(VaultException, "The :properties parameter is mandatory, and must be a hash")
    end

    v.set_properties(properties)
    v.save()

    return v.to_json(params)
  end

  post('/views/:view_id/get_properties') do |view_id|
    v = View.find(view_id)
    keys = params.delete(:keys)
    result = v.get_properties(keys)
    return result
  end

  post('/views/:view_id/new_segments') do |view_id|
    view = View.find(view_id)

    # Convert the segment names to strings instead of symbols
    segments = params.delete(:segments)
    segments.each do |segment|
      segment[:data] = Base64.decode64(segment[:data])
    end

    # Loop through the one or more segments we need to create and do them
    view.create_segments(segments)
    view.save()

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
      :since         => view.starting_revision,
    }.merge(params))
  end

  post('/views/:view_id/delete_segments') do |view_id|
    view = View.find(view_id)
    segments = params[:segments]

    # Delete the segments
    view.delete_segments(segments)
    view.save()

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
      :since         => view.starting_revision,
    }.merge(params))
  end

  post('/views/:view_id/delete_all_segments') do |view_id|
    view = View.find(view_id)
    view.delete_all_segments()
    view.save()

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
      :since         => view.starting_revision,
    }.merge(params))
  end

  post('/views/:view_id/new_nodes') do |view_id|
    view = View.find(view_id)

    if(params[:nodes].nil?)
      raise(VaultException, "Required field: 'nodes'.")
    end
    if(params[:segment].nil?)
      raise(VaultException, "Required field: 'segment'.")
    end

    view.create_nodes(
      :segment_name => params[:segment],
      :nodes        => params[:nodes],
    )
    view.save()

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => view.starting_revision,
    }.merge(params))
  end

  post('/views/:view_id/delete_nodes') do |view_id|
    view = View.find(view_id)
    segment_name = params[:segment]
    addresses = params[:addresses]
    view.delete_nodes({
      :segment_name => segment_name,
      :addresses    =>addresses
    })
    view.save()

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => view.starting_revision,
    }.merge(params))
  end

  post('/views/:view_id/undo') do |view_id|
    view = View.find(view_id)
    view.undo()
    view.save()

    result = view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => view.starting_revision,
    }.merge(params))

    return result
  end

  post('/views/:view_id/clear_undo_log') do |view_id|
    view = View.find(view_id)
    view.clear_undo_log()
    view.save()

    result = view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => view.starting_revision,
    }.merge(params))

    return result
  end

  post('/views/:view_id/redo') do |view_id|
    view = View.find(view_id)
    view.redo()
    view.save()

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
      :since         => view.starting_revision,
    }.merge(params))
  end

  get('/views/:view_id/segments') do |view_id|
    view = View.find(view_id)

    if(params[:with_data].nil?)
      params
    end
    if(params[:with_nodes].nil?)
      params[:with_nodes] = false
    end

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => false,
    }.merge(params))
  end

  get('/views/:view_id/nodes') do |view_id|
    view = View.find(view_id)

    return view.to_json({
      :with_segments => true, # These defaults will be overridden by the user's request
      :with_data     => false,
      :with_nodes    => true,
    }.merge(params))
  end

  get('/views/:view_id/debug/undo_log') do |view_id|
    view = View.find(view_id)

    return view.undo_to_json()
  end
end
