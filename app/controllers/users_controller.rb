require 'will_paginate/array'

class UsersController < ApplicationController
  autocomplete :user, :name
  # GETs should be safe (see http://www.w3.org/2001/tag/doc/whenToUseGet.html)
  verify method: :post, only: %i[destroy create update],
         redirect_to: {action: :list}

  def action_allowed?
    case params[:action]
    when 'keys'
       current_role_name.eql? 'Student'
    else
      ['Super-Administrator',
       'Administrator',
       'Instructor',
       'Teaching Assistant'].include? current_role_name
    end
  end

  def index
    if current_user_role? == "Student"
      redirect_to(action: AuthHelper.get_home_action(session[:user]), controller: AuthHelper.get_home_controller(session[:user]))
    else
      list
      render action: 'list'
    end
  end

  def auto_complete_for_user_name
    user = session[:user]
    role = Role.find(user.role_id)
    @users = User.where('name LIKE ? and (role_id in (?) or id = ?)', "#{params[:user][:name]}%", role.get_available_roles, user.id)
    render inline: "<%= auto_complete_result @users, 'name' %>", layout: false
  end

  #
  # for anonymized view for demo purposes
  #
  def set_anonymized_view
    anonymized_view_starter_ips = $redis.get('anonymized_view_starter_ips') || ''
    session[:ip] = request.remote_ip
    if anonymized_view_starter_ips.include? session[:ip]
      anonymized_view_starter_ips.delete!(" #{session[:ip]}")
    else
      anonymized_view_starter_ips += " #{session[:ip]}"
    end
    $redis.set('anonymized_view_starter_ips', anonymized_view_starter_ips)
    redirect_to :back
  end

  # for displaying the list of users
  def list
    #user = session[:user]
    @records_per_page = params[:records_per_page]
    @users = paginate_list(@records_per_page)
  end



  # Differences between show _selection and show:
  #   The key difference between show_selection and the show methods is in how they determine whether the current user has the authority to delete/edit a selected user
  #   The show method only checks if the current user is not a student or him/herself. It assumes that all other roles are authorised to edit/delete the information of all users.

  # determines if the current user is authorised to see/edit the information of the user in params.
  # the test used to determine is whether the current user is higher up the hierarchy of roles than the user s/he is requesting to edit.
  # If these permissions check out, the user is redirected to the 'show' view
  # If these checks come out negative, the user to given an error message and redirected to a list of all users.

  # show_selection is called from app/views/users/list.html.erb
  def show_selection
    @user = User.find_by(name: params[:user][:name])
    if !@user.nil?
      role
      if @role.parent_id.nil? || @role.parent_id < session[:user].role_id || @user.id == session[:user].id
        render action: 'show'
      else
        #else redirect with an error message
        flash[:note] = 'The specified user is not available for editing.'
        redirect_to action: 'list'
      end
      #redirect to the list of users if the user does not exist.
    else
      flash[:note] = params[:user][:name] + ' does not exist.'
      redirect_to action: 'list'
    end
  end


  #finds out the current user's role. If that is not a a student, permission is granted to edit the information of the requested user.
  # The show method is being called from app/views/users/show.html.erb
  def show
    # if permission is not granted, the current user is redirected to home.
    if params[:id].nil? || ((current_user_role? == "Student") && (session[:user].id != params[:id].to_i))
      redirect_to(action: AuthHelper.get_home_action(session[:user]), controller: AuthHelper.get_home_controller(session[:user]))
    else
      #find the users information from the model.
      @user = User.find(params[:id])
      role
      # obtain number of assignments participated
      @assignment_participant_num = 0
      AssignmentParticipant.where(user_id: @user.id).each {|_participant| @assignment_participant_num += 1 }
      # judge whether this user become reviewer or reviewee
      @maps = ResponseMap.where('reviewee_id = ? or reviewer_id = ?', params[:id], params[:id])
      # count the number of users in DB
      @total_user_num = User.count
    end
  end

  def new
    @user = User.new
    @rolename = Role.find_by(name: params[:role])
    foreign
  end


  def create
    # if the user name already exists, register the user by email address
    check = User.find_by(name: params[:user][:name])
    params[:user][:name] = params[:user][:email] unless check.nil?
    @user = User.new(user_params)
    @user.institution_id = params[:user][:institution_id]
    # record the person who created this new user
    @user.parent_id = session[:user].id
    # set the user's timezone to its parent's
    @user.timezonepref = User.find(@user.parent_id).timezonepref
    if @user.save
      password = @user.reset_password # the password is reset
      prepared_mail = MailerHelper.send_mail_to_user(@user, "Your Expertiza account and password have been created.", "user_welcome", password)
      prepared_mail.deliver
      flash[:success] = "A new password has been sent to new user's e-mail address."
      # Instructor and Administrator users need to have a default set for their notifications
      # the creation of an AssignmentQuestionnaire object with only the User ID field populated
      # ensures that these users have a default value of 15% for notifications.
      # TAs and Students do not need a default. TAs inherit the default from the instructor,
      # Students do not have any checks for this information.
      AssignmentQuestionnaire.create(user_id: @user.id) if @user.role.name == "Instructor" or @user.role.name == "Administrator"
      undo_link("The user \"#{@user.name}\" has been successfully created. ")
      redirect_to action: 'list'
    else
      foreign
      render action: 'new'
    end
  end

  def edit
    @user = User.find(params[:id])
    role
    foreign
  end

  def update
    params.permit!
    @user = User.find params[:id]
    # update username, when the user cannot be deleted
    # rename occurs in 'show' page, not in 'edit' page
    # eg. /users/5408?name=5408
    @user.name += '_hidden' if request.original_fullpath == "/users/#{@user.id}?name=#{@user.id}"

    if @user.update_attributes(params[:user])
      flash[:success] = "The user \"#{@user.name}\" has been successfully updated."
      redirect_to @user
    else
      render action: 'edit'
    end
  end

  def destroy
    begin
      @user = User.find(params[:id])
      AssignmentParticipant.where(user_id: @user.id).each(&:delete)
      TeamsUser.where(user_id: @user.id).each(&:delete)
      AssignmentQuestionnaire.where(user_id: @user.id).each(&:destroy)
      # Participant.delete(true)
      @user.destroy
      flash[:note] = "The user \"#{@user.name}\" has been successfully deleted."
    rescue StandardError
      flash[:error] = $ERROR_INFO
    end

    redirect_to action: 'list'
  end

  def keys
    if params[:id].nil? || ((current_user_role? == "Student") && (session[:user].id != params[:id].to_i))
      redirect_to(action: AuthHelper.get_home_action(session[:user]), controller: AuthHelper.get_home_controller(session[:user]))
    else
      @user = User.find(params[:id])
      @private_key = @user.generate_keys
    end
  end

  protected

  # finds the list of roles that the current user can have
  # used to display a dropdown selection of roles for the current user in the views
  def foreign
    # finds what the role of the current user is.
    role = Role.find(session[:user].role_id)

    # this statement finds a list of roles that the current user can have
    # The @all_roles variable is used in the view to present the user a list of options
    # of the roles they may select from.
    @all_roles = Role.where('id in (?) or id = ?', role.get_available_roles, role.id)
  end

  private

  def user_params
    params.require(:user).permit(:name,
                                 :crypted_password,
                                 :role_id,
                                 :password_salt,
                                 :fullname,
                                 :email,
                                 :parent_id,
                                 :private_by_default,
                                 :mru_directory_path,
                                 :email_on_review,
                                 :email_on_submission,
                                 :email_on_review_of_review,
                                 :is_new_user,
                                 :master_permission_granted,
                                 :handle,
                                 :digital_certificate,
                                 :persistence_token,
                                 :timezonepref,
                                 :public_key,
                                 :copy_of_emails,
                                 :institution_id)
  end


  def role
    if @user && @user.role_id
      @role = Role.find(@user.role_id)
    elsif @user
      @role = Role.new(id: nil, name: '(none)')
    end
  end

  # For filtering the users list with proper search and pagination.
  def paginate_list(records_per_page)
    paginate_options = {"1" => 25, "2" => 50, "3" => 100, "4" => User.count}
    # If the above hash does not have a value for the key,
    # it means that we need to show all the users on the page
    #
    # Just a point to remember, when we use pagination, the
    # 'users' variable should be an object, not an array

    # call is commented out due to broken search functionality
    
    # The type of condition for the search depends on what the user has selected from the search_by dropdown
    #@search_by = params[:search_by]
    # search for corresponding users
    # users = User.search_users(role, user_id, letter, @search_by)

    # paginate
    users = if paginate_options[records_per_page.to_s].nil? # displaying Default 25 records per page
              User.all.paginate(page: params[:page], per_page: paginate_options["1"])
            else # some pagination is active - use the per_page
              User.all.paginate(page: params[:page], per_page: paginate_options[records_per_page.to_s])
            end
    users
  end

  # generate the undo link
  # def undo_link
  #  "<a href = #{url_for(:controller => :versions,:action => :revert,:id => @user.versions.last.id)}>undo</a>"
  # end
end
