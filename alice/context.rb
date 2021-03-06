class Context
  require 'thread'
  include Mongoid::Document

  field :topic
  field :keywords, type: Array, default: []
  field :corpus, type: Array, default: []
  field :expires_at, type: DateTime
  field :has_user, type: Boolean, default: false
  field :is_current, type: Boolean
  field :is_ephemeral, type: Boolean, default: false
  field :spoken, type: Array, default: []
  field :created_at, type: DateTime

  before_create :downcase_topic, :define_corpus, :extract_keywords, :set_user
  before_create :set_expiry

  validates_uniqueness_of :topic, case_sensitive: false

  store_in collection: "alice_contexts"

  AMBIGUOUS = "That may refer to several different things. Can you clarify?"
  MINIMUM_FACT_LENGTH = 15
  TTL = 30

  attr_accessor :corpus_from_user, :query

  def self.with_keywords
    where(:keywords.not => { "$size" => 0 })
  end

  def self.current
    if context = where(is_current: true).desc(:expires_at).last
      ! context.expire && context
    end
  end

  def self.keywords_from(topic)
    topic.to_s.downcase.scan(/[a-zA-Z]+/) - Grammar::LanguageHelper::PREDICATE_INDICATORS
  end

  def self.find_or_create(topic, query="")
    context = from(topic) || new(topic: topic)
    unless query.empty?
      context.query = query.downcase.gsub(ENV['BOT_NAME'], "").gsub(/\<\#{User.bot.slack_id}\>/, "")
      if context.persisted?
        context.define_corpus
        context.save
      end
    end
    context
  end

  def self.most_recent
    Context.all.order_by(updated_at: 'desc').first
  end

  def self.with_pronouns_matching(pronouns)
    candidates = Context.where(:has_user => true).order_by(:updated_at => 'desc')
    candidates.each do |candidate|
      return candidate if (["they", "them", "their"] & pronouns).any?
      return candidate if candidate.context_user && (candidate.context_user.pronouns_enumerated & pronouns).any?
    end
    return nil
  end

  def self.with_topic_matching(topic)
    ngrams = Grammar::NgramFactory.new(topic).omnigrams
    ngrams = ngrams.map{|g| g.join(' ')}
    if exact_match = any_in(topic: ngrams).first
      return exact_match
    end
    return nil
  end

  def self.with_keywords_matching(topic)
    topic_keywords = keywords_from(topic)
    any_in(keywords: topic_keywords + [topic_keywords.join(" ")]).sort do |a,b|
      (a.keywords & topic_keywords).count <=> (b.keywords & topic_keywords).count
    end.last
  end

  def self.from(*topic)
    topic.join(' ') if topic.respond_to?(:join)
    context = with_topic_matching(topic)
    context ||= with_keywords_matching(topic)
    context
  end

  def ambiguous?
    self.corpus && self.corpus.map{|fact| fact.include?("may refer to") || fact.include?("disambiguation") }.any?
  end

  def context_user
    @context_user ||= User.from(self.topic)
  end

  def corpus_accessor
    return corpus unless is_ephemeral
    if self.corpus == nil
      define_corpus
    end
    corpus
  end

  def current!
    Context.all.each{|context| context.update_attribute(:is_current, false) }
    update_attributes(is_current: true, expires_at: DateTime.now + TTL.minutes)
  end

  def describe
    return AMBIGUOUS if ambiguous?
    fact = facts.select{ |sentence| near_match(self.topic, sentence) }.first
    record_spoken(fact)
    fact
  end

  def define_corpus
    self.corpus ||= []
    self.corpus << begin
      content = fetch_content_from_sources
      content.reject!{ |s| s.size < (self.corpus_from_user ? self.topic.length + 1 : MINIMUM_FACT_LENGTH)}
      content
    rescue Exception => e
      Alice::Util::Logger.info "*** Unable to fetch corpus for \"#{self.topic}\": #{e}"
      Alice::Util::Logger.info e.backtrace
      nil
    end
    self.corpus.flatten!.compact!
  end

  def declarative_fact(subtopic, speak=true)
    return AMBIGUOUS if ambiguous?
    sorted_facts = Grammar::DeclarativeSorter.sort(query: subtopic, corpus: self.corpus)
    unspoken_facts = sorted_facts - self.spoken
    if unspoken_facts.any?
      fact = unspoken_facts.first
      record_spoken(fact) if speak
    else
      fact = sorted_facts.first
    end
    fact
  end

  def expire
    expire! if (self.expires_at.nil? || self.expires_at < DateTime.now)
  end

  def facts
    spoken_facts = corpus_accessor.to_a.select{|sentence| spoken.include? sentence}
    if spoken_facts.count == corpus_accessor.to_a.count # We've said all we can, time to repeat ourselves
      corpus_accessor.to_a
    else
      corpus_accessor.to_a.reject{|sentence| spoken.include? sentence}.uniq
    end
  end

  def has_spoken_about?(topic)
    self.spoken.to_s.downcase.include?(topic.downcase)
  end

  def inspect
    %{#<Context _id: #{self.id}", topic: "#{self.topic}", keywords: #{self.keywords}, is_current: #{is_current}, expires_at: #{self.expires_at}"}
  end

  def random_fact
    return AMBIGUOUS if ambiguous?
    facts.sample
  end

  def relational_fact(subtopic, spoken=true)
    return AMBIGUOUS if ambiguous?
    fact = relational_facts(subtopic).sample
    record_spoken(fact) if spoken
    fact
  end

  def targeted_fact(subtopic, spoken=true)
    return AMBIGUOUS if ambiguous?
    unspoken_facts = self.spoken - targeted_fact_candidates(subtopic).first
    record_spoken(fact) if spoken
    fact
  end

  private

  def downcase_topic
    self.topic.downcase!
  end

  def extract_keywords
    self.keywords += begin
      parsed_corpus = Grammar::SentenceParser.parse(corpus.join(' '))
      candidates = parsed_corpus.nouns + parsed_corpus.adjectives
      candidates = candidates.inject(Hash.new(0)) {|h,i| h[i] += 1; h }
      candidates.select{|k,v| v > 1}.map(&:first).map(&:downcase).uniq
    rescue
      []
    end
  end

  def expire!
    update_attributes(is_current: false, spoken: [])
  end

  def fetch_content_from_sources
    user_content = Parser::User.fetch(topic)
    if user_content.any?
      @content = user_content
      self.corpus_from_user = true
      self.is_ephemeral = true
      return @content.flatten
    end

    @content ||= []

    mutex = Mutex.new
    threads = []

    search_string = (self.query && !self.query.empty?) ? self.query : self.topic
    threads << Thread.new() do
      c = Parser::Alpha.fetch_all(search_string) # TODO should this be query?
      mutex.synchronize { @content << c }
    end

    threads << Thread.new() do
      c = Parser::Google.fetch_all(search_string)
      mutex.synchronize { @content << c }
    end

    threads << Thread.new() do
      c = Parser::Google.fetch_all("facts about #{topic}")
      mutex.synchronize { @content << c }
    end

    threads << Thread.new() do
      c = Parser::Wikipedia.fetch_all(topic)
      mutex.synchronize { @content << c }
    end

    threads.each(&:join)
    @content = @content.flatten.compact.reject(&:empty?)
    @content = @content.map{ |fact| Sanitize.clean(fact.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')).strip }.uniq
    @content = @content.reject{ |fact| Grammar::SentenceParser.parse(fact).verbs.empty? }
    @content = @content.reject{ |fact| fact =~ /click/i || fact =~ /website/i || fact =~ /quiz/i }
    @content = @content.reject{ |s| s.include?("may refer to") || s.include?("disambiguation") }
    @content = @content.map{ |s| Grammar::LanguageHelper.to_third_person(s.gsub(/^\**/, "")) }
    @content = @content.uniq
    @content
  end

  def near_match(subject, sentence)
    (sentence.downcase.split & subject.split).size > 0
  end

  def record_spoken(fact)
    return unless fact
    self.spoken << fact
    update_attribute(:spoken, self.spoken.uniq)
  end

  def relational_facts(subtopic)
    @relational_facts ||= begin
      subtopic_ngrams = Grammar::NgramFactory.new(subtopic).omnigrams
      subtopic_ngrams = subtopic_ngrams.map{|g| g.join(' ')}.reverse
      candidates = subtopic_ngrams.map{ |ngram| facts.select{|fact| fact =~ /#{ngram}/i} }.compact.flatten
      candidates.select do |sentence|
        placement = position_of(subtopic.downcase, sentence.downcase)
        placement && placement.to_i < 100
      end.uniq
    end
  end

  def set_expiry
    self.expires_at = DateTime.now + TTL.minutes
  end

  def set_user
    self.has_user = !!User.from(self.topic)
    return true
  end

  def targeted_fact_candidates(subtopic)
    subtopic_ngrams = Grammar::NgramFactory.new(subtopic).omnigrams
    subtopic_ngrams = subtopic_ngrams.map{|g| g.join(' ')}.reverse
    subtopic_ngrams.map{ |ngram| facts.select{|fact| fact =~ /#{ngram}/i} }.compact.flatten
  end
end
