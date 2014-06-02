$LOAD_PATH << '.'

require 'json'
require 'sinatra'
require 'tempfile'

require 'elf'
#require 'pe'

set :show_exceptions, false
set :bind, "0.0.0.0"
set :port, 4567

def get_file(params)
  file = Tempfile.new('h2gb-babel')
  file.write(params['file'])
  file.close()
  filename = file.path

  yield file.path

  file.unlink()
end

error do
  content_type :json
  status 400 # or whatever

  e = env['sinatra.error']

  result = {
    :status => 0,
    :e => e
  }

  return JSON.pretty_generate(result) + "\n"
end

get '/' do
  return 'Welcome to h2gb!'
end

post '/disassemble/elf' do
  content_type :json
  data = nil
  get_file(params) do |filename|
    data = parse_elf(filename, true)
  end

  data[:status] = 1

  return JSON.pretty_generate(data) + "\n"
end

post '/disassemble/pe' do
  
end

get '/test' do
  return <<EOF
  <form method='post' action='/disassemble/elf' enctype='multipart/form-data'>
    <input type='file' name='file' /><br />
    <input type='submit' />
  </form>
  <form method='post' action='/disassemble/elf' enctype='multipart/form-data'>
    <input type='type' name='file' /><br />
    <input type='submit' />
  </form>
EOF

end
