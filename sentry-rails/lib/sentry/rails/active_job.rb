module Sentry
  module Rails
    module ActiveJobExtensions
      def self.included(base)
        base.class_eval do
          around_perform do |job, block|
            if Sentry.initialized?
              if already_supported_by_specific_integration?(job)
                block.call
              else
                Sentry.with_scope do |scope|
                  capture_and_reraise_with_sentry(job, scope, block)
                end
              end
            else
              block.call
            end
          end
        end
      end

      def capture_and_reraise_with_sentry(job, scope, block)
        scope.set_transaction_name(job.class.name)
        span = Sentry.start_transaction(name: scope.transaction_name, op: "active_job")

        scope.set_span(span)

        block.call

        span.set_http_status(200)
        span.finish
      rescue Exception => e # rubocop:disable Lint/RescueException
        rescue_handler_result = rescue_with_handler(e)
        span.set_http_status(500)
        span.finish
        return rescue_handler_result if rescue_handler_result

        Sentry::Rails.capture_exception(
          e,
          extra: sentry_context(job),
          tags: {
            job_id: job.job_id,
            provider_job_id: job.provider_job_id
          }
        )
        raise e
      end

      def already_supported_by_specific_integration?(job)
        Sentry.configuration.rails.skippable_job_adapters.include?(job.class.queue_adapter.class.to_s)
      end

      def sentry_context(job)
        {
          active_job: job.class.name,
          arguments: job.arguments,
          scheduled_at: job.scheduled_at,
          job_id: job.job_id,
          provider_job_id: job.provider_job_id,
          locale: job.locale
        }
      end
    end
  end
end

class ActiveJob::Base
  include Sentry::Rails::ActiveJobExtensions
end
