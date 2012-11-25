﻿# coding: utf-8
class EventsController < ApplicationController
  load_and_authorize_resource

  # GET /events
  # GET /events.json
  def index
    @events = @events.page(params[:page]).per(50).order('updated_at desc')
    params[:tag_id].blank? or
      @events = @events.by_tag_ids(params[:tag_id])
    params[:g_calendar_id].blank? or
      @events = @events.where(:g_calendar_id => params[:g_calendar_id])
    params[:include_delete].blank? and
      @events = @events.active

    respond_with @events, :include=> [:tags,  :uris]
  end

  # GET /events/1
  # GET /events/1.json
  def show
    respond_with @event, :include=> [:tags,  :uris]
  end

  # GET /events/new
  # GET /events/new.json
  def new
    # TODO 回数はとりあえず固定
    # TODO: これはやめよう。動的に作るべき。 (gull08)
    2.times { @event.uris.build }
    2.times { @event.tags.build }
    respond_with @event
  end

  # GET /events/1/edit
  def edit
  end

  # POST /events
  # POST /events.json
  def create
    # TODO Googleに一度登録してからデータを流用とか？
    # TODO: etag は SecureRandom でもなんでも適当に生成すればいいとおもう (gull08)
    # TODO: そして、ここじゃなくてモデルでやるべき (gull08)
    @event.etag='etag'
    @event.ical_uid='ical_uid'
    @event.save
    respond_with @event
  end

  # PUT /events/1
  # PUT /events/1.json
  def update
    @event.update_attributes(params[:event])
    respond_with @event
  end

  # DELETE /events/1
  # DELETE /events/1.json
  def destroy
    @event.update_attirbute! :status => 'cancelled'
    respond_with @event
  end
end
