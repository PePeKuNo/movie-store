class HomeController < ApplicationController
  def index
    @regions = RegionRegistry.all
  end
end
