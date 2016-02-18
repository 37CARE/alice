module Handlers

  class Emotes

    include PoroPlus
    include Behavior::HandlesCommands

    def cast
      message.set_response(Util::Randomizer.spell_effect(message.sender_nick, command_string.predicate))
    end

    def dance
      response = "Looks like you're dancing with yourself there."
      if person = ::User.from(command_string.subject)
        if person.is_online? && person != message.sender
          response = Util::Randomizer.dance(message.sender_nick, person.current_nick)
        elsif ! person.is_online?
          response = "You can't dance with #{person.pronoun_objective} when #{person.pronoun_contraction} asleep!"
        end
      elsif actor = ::Actor.from(command_string.subject)
        response = Util::Randomizer.dance(message.sender_nick, actor.proper_name)
      end
      message.set_response(response)
    end

    def commands
      response = "I understand the following commands: "
      response << Command.all.map(&:verbs).map do |verbs|
        verb = verbs.detect{|verb| verb =~ /[a-z]+/ && "!#{verb}"}
        verb.present? && "!#{verb}" || nil
      end.flatten.compact.sort.join(", ")
      message.set_response(response)
    end

    def help
      response = []
      response << "For most things you can ask me or tell me something in plain English."
      response << "For other things, try !<<command>>. For example:"
      response << "!bio sets your bio, !fact sets a fact about yourself, and !twitter sets your Twitter handle."
      response << "!pronouns sets your preferred pronouns (just type !pronouns for help)."
      response << "!look, !inventory, !forge, and !brew can come in handy sometimes."
      response << "Also: beware the fruitcake."
      message.set_response(response.join("\r\n"))
    end

    def seen
      user = ::User.from(command_string.subject)
      response = "I last saw #{user.current_nick} #{user.last_seen}."
      message.set_response(response)
    end

    def stats
      response = []
      response << "I'm currently managing #{::User.count} users, #{::Item.count} items, #{::Actor.count} actors, and #{::Place.count} rooms."
      response << "I'm capable of responding to #{::Message::Command.count} distinct commands."
      response << "I've overheard #{::OH.count} things and I know #{::Factoid.count} facts."
      response << "I can converse on #{Context.count} different topics, including #{Context.with_keywords.sample.topic}."
      response << "Pretty cool, huh?"
      message.set_response(response.join("\r\n"))
    end

    def source
      response = ["My source code is available at #{ENV['GITHUB_URL']}."]
      response << "You can see my latest commits with !commits, and a list of recent open issues with !issues."
      response << "For a list of contributors, try !contributors."
      message.set_response(response.join("\n"))
    end

    def bug
      message.set_response("Please submit bug reports at #{ENV['ISSUES_URL']}")
    end

    def love
      message.set_response("I love you too!")
    end

    def one_ring
      message.set_response("...and in the darkness bind them.")
    end

    def so_say_we_all
      message.set_response("So say we all!")
    end

    def youre_welcome
      message.set_response(Util::Randomizer.thanks_response(message.sender_nick))
    end

  end

end
