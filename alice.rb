require 'rubygems'
require 'bundler'
require 'bundler/setup'
require 'cinch'
require 'dotenv'

Dotenv.load
Bundler.require
Mongoid.load!("config/mongoid.yml")

module Alice

  require_relative 'alice/handlers/bio'
  require_relative 'alice/handlers/factoid'
  require_relative 'alice/handlers/greeting'
  require_relative 'alice/handlers/twitter'
  
  require_relative 'alice/listeners/setter'
  require_relative 'alice/listeners/core'
  require_relative 'alice/listeners/nlp'
  require_relative 'alice/listeners/treasure'

  require_relative 'alice/parser/language_helper'
  require_relative 'alice/parser/ngram'
  require_relative 'alice/parser/ngram_factory'

  require_relative 'alice/bot'
  require_relative 'alice/command'
  require_relative 'alice/factoid'
  require_relative 'alice/response'
  require_relative 'alice/treasure'
  require_relative 'alice/user'
  
  def self.start
    @@bot = Alice::Bot.new
    @@bot.start
  end

  def self.bot
    @@bot ||= Alice::Bot.new
  end

end