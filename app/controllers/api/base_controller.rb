module Api
  class BaseController < ApplicationController
    protect_from_forgery with: :null_session

    rescue_from ArgumentError, ActionController::ParameterMissing do |error|
      render json: { "error" => error.message }, status: :bad_request
    end

    private

    # -- generation parameters shared by the movie and trailer endpoints ----

    def current_region
      RegionRegistry.find(params[:region])
    end

    def current_seed
      SeedParser.parse(params[:seed])
    end

    def current_page
      [ [ params[:page].to_i, 1 ].max, 100_000 ].min
    end

    def current_likes
      clamp_rate(params[:likes])
    end

    def current_reviews
      clamp_rate(params[:reviews])
    end

    def clamp_rate(value)
      number = value.to_f
      return 0.0 if number.nan?

      number.clamp(0.0, 10.0)
    end

    # One generator per request: `page` records the plans it just produced in
    # `last_plans`, and the caller (movies#index) hands exactly those to the
    # poster queue. Building a new instance for every call silently dropped
    # that hand-off, so the queue never got warmed.
    def generator(likes: nil, reviews: nil)
      @generator ||= MovieGenerator.new(
        region: current_region,
        seed: current_seed,
        likes: likes || current_likes,
        reviews: reviews || current_reviews
      )
    end

    def record_index
      index = params[:index].to_i
      raise ArgumentError, "index out of range" if index.negative? || index >= MovieGenerator::PAGE_SIZE

      index
    end

    def trailer_plan
      @trailer_plan ||= generator.plan_for(current_page, record_index)
    end

    def quality
      %w[hd sd ld].include?(params[:quality]) ? params[:quality] : "hd"
    end
  end
end
