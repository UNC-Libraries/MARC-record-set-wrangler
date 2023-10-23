
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "marc_wrangler/version"

Gem::Specification.new do |spec|
  spec.name          = "marc_wrangler"
  spec.version       = MarcWrangler::VERSION
  spec.authors       = ["Kristina Spurgin"]
  spec.email         = ["kspurgin@email.unc.edu"]

  spec.summary       = 'Diff MARC record sets based on specified criteria. Split/tag incoming MARC set to meet your needs.'
  spec.description   = 'See summary.'
  spec.homepage      = "https://github.com/UNC-Libraries/MARC-record-set-wrangler/wiki"
  spec.license       = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 2.1"
  spec.add_development_dependency "rake", "~> 12.3", ">= 12.3.3"
  spec.add_development_dependency "rspec", "~> 3.0"

  spec.add_runtime_dependency 'highline', "~> 2.0.1"
  spec.add_runtime_dependency 'marc', "~> 1.1"
  spec.add_runtime_dependency 'enhanced_marc', "~> 0.3.2"

  # unf_ext 0.0.7.6 was released without windows binaries
  spec.add_runtime_dependency 'unf_ext', "0.0.7.5"
end
