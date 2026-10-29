module Api
  class MoviesController < BaseController
    # One page (batch) of movies, generated on the fly. No database, no
    # storage: the response is computed from (region, seed, likes, reviews,
    # page) alone and is therefore perfectly reproducible.
    def index
      gen = generator
      items = gen.page(current_page)

      # Start rendering this page's posters in the background right away:
      # they are ready before the browser has finished parsing the response,
      # and the poster endpoint itself never blocks a worker thread.
      TrailerRenderer.warm_posters(gen.last_plans || [])

      render json: {
        "region" => current_region.tag,
        "seed" => current_seed.to_s,
        "page" => current_page,
        "pageSize" => MovieGenerator::PAGE_SIZE,
        "likes" => current_likes,
        "reviews" => current_reviews,
        "hasMore" => true,
        "items" => items
      }
    end
  end
end
