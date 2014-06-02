$LOAD_PATH << '.'

require 'json'
require 'sinatra'
require 'tempfile'

require 'elf'

get '/' do
  return 'hi'
end

post '/disassemble/elf' do
  if(params['file'].is_a?(Hash))
    filename = params['file'][:tempfile]

    data = parse_elf(filename, true)
  else
    file = Tempfile.new('h2gb-babel')
    file.write(params['file'])
    file.close()
    filename = file.path

    data = parse_elf(filename, true)

    file.unlink()
  end

  puts(data.inspect)

  return JSON.pretty_generate(data)
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
