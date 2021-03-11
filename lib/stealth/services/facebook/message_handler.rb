# coding: utf-8
# frozen_string_literal: true

require 'stealth/services/facebook/events/message_event'
require 'stealth/services/facebook/events/postback_event'
require 'stealth/services/facebook/events/message_reads_event'
require 'stealth/services/facebook/events/messaging_referral_event'

module Stealth
  module Services
    module Facebook

      class MessageHandler < Stealth::Services::BaseMessageHandler

        attr_reader :service_message, :params, :headers, :facebook_message

        def initialize(params:, headers:)
          @params = params
          @headers = headers
        end

        def coordinate
          if facebook_is_validating_webhook?
            respond_with_validation
          else
            # Queue the request processing so we can respond quickly to FB
            # and also keep track of this message
            Stealth::Services::HandleMessageJob.perform_async(
              'facebook',
              params,
              headers
            )

            # Relay our acceptance
            [200, 'OK']
          end
        end

        def process
          @service_message = ServiceMessage.new(service: 'facebook')
          @facebook_message = params['entry'].first['messaging'].first
          p @facebook_message
          page_id = facebook_page_id
          page_access_token = facebook_page_access_token(page_id)
          service_message.page_info = {
            id: page_id,
            access_token: page_access_token
          }
          service_message.sender_id = get_sender_id
          service_message.target_id = get_target_id
          service_message.timestamp = get_timestamp
          process_facebook_event

          service_message
        end

        private

        def facebook_is_validating_webhook?
          params['hub.verify_token'].present?
        end

        def respond_with_validation
          if params['hub.verify_token'] == Stealth.config.facebook.verify_token
            [200, params['hub.challenge']]
          else
            [401, "Verify token did not match environment variable."]
          end
        end

        def get_sender_id
          facebook_message['sender']['id']
        end

        def get_target_id
          facebook_message['recipient']['id']
        end

        def get_timestamp
          Time.at(facebook_message['timestamp']/1000).to_datetime
        end

        def facebook_page_id
          params['entry'].first['id']
        end

        def facebook_page_access_token(page_id)
          redis_key = "facebook:#{page_id}"
          access_token = redis_backed_storage.hget(redis_key, 'access_token') || Stealth.config.facebook.page_access_token
          raise "Cannot find access token for FB page #{page_id}" if access_token.blank?

          access_token
        end

        def process_facebook_event
          if facebook_message['message'].present?
            message_event = Stealth::Services::Facebook::MessageEvent.new(
              service_message: service_message,
              params: facebook_message
            )
          elsif facebook_message['postback'].present?
            message_event = Stealth::Services::Facebook::PostbackEvent.new(
              service_message: service_message,
              params: facebook_message
            )
          elsif facebook_message['read'].present?
            message_event = Stealth::Services::Facebook::MessageReadsEvent.new(
              service_message: service_message,
              params: facebook_message
            )
          elsif facebook_message['referral'].present?
            message_event = Stealth::Services::Facebook::MessagingReferralEvent.new(
              service_message: service_message,
              params: facebook_message
            )
          end

          message_event.process
        end
      end
    end
  end
end
