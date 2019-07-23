# standard library
require 'date'

# external gems
require 'marc'
require 'highline/import'

# marc extension
require_relative 'ext/marc/reader.rb'

require_relative 'marc_wrangler/record_info.rb'

module MarcWrangler
  autoload :VERSION, 'marc_wrangler/version'
  autoload :ProcessHoldings, 'marc_wrangler/process_holdings'
end
