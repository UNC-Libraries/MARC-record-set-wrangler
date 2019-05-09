# standard library
require 'date'

# external gems
require 'marc'
require 'highline/import'

module MarcWrangler
  autoload :VERSION, 'marc_wrangler/version'
  autoload :ProcessHoldings, 'marc_wrangler/process_holdings'
end
