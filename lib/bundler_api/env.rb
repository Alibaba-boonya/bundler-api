require 'dotenv'

module BundlerApi
  class Env
    def self.load
      Dotenv.load '.env.local', '.env'
    end
  end
end

BundlerApi::Env.load
