require 'net/imap'

class Inboxes::FetchImapEmailsJob < ApplicationJob
  queue_as :low

  def perform(channel)
    return unless should_fetch_email?(channel)

    if channel.ms_oauth_token_available?
      fetch_mail_for_ms_oauth_channel(channel)
    else
      fetch_mail_for_channel(channel)
    end
    # clearing old failures like timeouts since the mail is now successfully processed
    channel.reauthorized!
  rescue *ExceptionList::IMAP_EXCEPTIONS
    channel.authorization_error!
  rescue EOFError => e
    Rails.logger.error e
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  private

  def should_fetch_email?(channel)
    channel.imap_enabled? && !channel.reauthorization_required?
  end

  def fetch_mail_for_channel(channel)
    # TODO: rather than setting this as default method for all mail objects, lets if can do new mail object
    # using Mail.retriever_method.new(params)
    Mail.defaults do
      retriever_method :imap, address: channel.imap_address,
                              port: channel.imap_port,
                              user_name: channel.imap_login,
                              password: channel.imap_password,
                              enable_ssl: channel.imap_enable_ssl
    end

    Mail.find(what: :last, count: 10, order: :asc).each do |inbound_mail|
      next if channel.inbox.messages.find_by(source_id: inbound_mail.message_id).present?

      process_mail(inbound_mail, channel)
    end
  end

  def fetch_mail_for_ms_oauth_channel(channel)
    access_token = valid_imap_ms_oauth_token channel

    return unless access_token

    # auth = 'Bearer ' + access_token
    # all_mails = HTTParty.get("https://graph.microsoft.com/v1.0/me/mailfolders/inbox/messages", :headers => { "Authorization" => auth })['value']

    # all_mails.each do |mail|
    #   inbound_mail = Mail.read_from_string mail
    #   next if channel.inbox.messages.find_by(source_id: inbound_mail['id'].value).present?

    #   process_mail(inbound_mail, channel)
    # end

    imap = Net::IMAP.new(channel.imap_address, channel.imap_port, true)
    imap.authenticate('XOAUTH2', channel.imap_login, access_token)
    imap.select('INBOX')
    imap.search(['ALL']).each do |message_id|
      inbound_mail =  Mail.read_from_string imap.fetch(message_id,'RFC822')[0].attr['RFC822']

      next if channel.inbox.messages.find_by(source_id: inbound_mail.message_id).present?

      process_mail(inbound_mail, channel)
    end
  end

  def process_mail(inbound_mail, channel)
    Imap::ImapMailbox.new.process(inbound_mail, channel)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  def valid_imap_ms_oauth_token(channel)
    Channels::RefreshMsOauthTokenJob.new.access_token(channel, channel.ms_oauth_token_hash.with_indifferent_access)
  end
end
