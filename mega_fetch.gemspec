$LOAD_PATH.unshift '.'

Gem::Specification.new do |s|
  s.name              = 'mega_fetch'
  s.version           = 0.1
  s.date              = Time.now.strftime('%Y-%m-%d')
  s.summary           = "Facebook OpenGraph API batch client for Ruby 1.9"
  s.email             = 'mikewadhera@gmail.com'
  s.authors           = ["Mike Wadhera"]

  s.files             = %w( README.rdoc mega_fetch.rb )

  s.extra_rdoc_files  = [ "README.rdoc" ]
  s.rdoc_options      = ["--charset=UTF-8"]

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<yajl-ruby>)
    else
      s.add_runtime_dependency(%q<yajl-ruby>)
    end
  else
    s.add_runtime_dependency(%q<yajl-ruby>)
  end
end
