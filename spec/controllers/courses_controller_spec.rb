#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe CoursesController do
  describe "GET 'index'" do
    it "should force login" do
      course_with_student(:active_all => true)
      get 'index'
      response.should be_redirect
    end
    
    it "should assign variables" do
      course_with_student_logged_in(:active_all => true)
      get 'index'
      response.should be_success
      assigns[:current_enrollments].should_not be_nil
      assigns[:current_enrollments].should_not be_empty
      assigns[:current_enrollments][0].should eql(@enrollment)
      assigns[:past_enrollments].should_not be_nil
    end
  end
  
  describe "GET 'settings'" do
    it "should require authorization" do
      course_with_teacher(:active_all => true)
      get 'settings', :course_id => @course.id
      assert_unauthorized
    end
    
    it "should should not allow students" do
      course_with_student_logged_in(:active_all => true)
      get 'settings', :course_id => @course.id
      assert_unauthorized
    end

    it "should render properly" do
      course_with_teacher_logged_in(:active_all => true)
      get 'settings', :course_id => @course.id
      response.should be_success
      response.should render_template("settings")
    end
  end
  
  describe "GET 'enrollment_invitation'" do
    it "should successfully reject invitation for logged-in user" do
      course_with_student_logged_in(:active_course => true)
      post 'enrollment_invitation', :course_id => @course.id, :reject => '1', :invitation => @enrollment.uuid
      response.should be_redirect
      response.should redirect_to(dashboard_url)
      assigns[:pending_enrollment].should eql(@enrollment)
      assigns[:pending_enrollment].should be_rejected
    end
    
    it "should successfully reject invitation for not-logged-in user" do
      course_with_student(:active_course => true, :active_user => true)
      post 'enrollment_invitation', :course_id => @course.id, :reject => '1', :invitation => @enrollment.uuid
      response.should be_redirect
      response.should redirect_to(root_url)
      assigns[:pending_enrollment].should eql(@enrollment)
      assigns[:pending_enrollment].should be_rejected
    end
    
    it "should not reject invitation for bad parameters" do
      course_with_student(:active_course => true, :active_user => true)
      post 'enrollment_invitation', :course_id => @course.id, :reject => '1', :invitation => @enrollment.uuid + 'a'
      response.should be_redirect
      response.should redirect_to(course_url(@course.id))
      assigns[:pending_enrollment].should be_nil
    end
    
    it "should accept invitation for logged-in user" do
      course_with_student_logged_in(:active_course => true, :active_user => true)
      post 'enrollment_invitation', :course_id => @course.id, :accept => '1', :invitation => @enrollment.uuid
      response.should be_redirect
      response.should redirect_to(course_url(@course.id))
      assigns[:pending_enrollment].should eql(@enrollment)
      assigns[:pending_enrollment].should be_active
    end
    
    it "should ask user to login for registered not-logged-in user" do
      user_with_pseudonym(:active_course => true, :active_user => true)
      course(:active_all => true)
      @enrollment = @course.enroll_user(@user)
      post 'enrollment_invitation', :course_id => @course.id, :accept => '1', :invitation => @enrollment.uuid
      response.should be_redirect
      response.should redirect_to(login_url)
    end
    
    it "should defer to registration_confirmation for pre-registered not-logged-in user" do
      user_with_pseudonym
      course(:active_course => true, :active_user => true)
      @enrollment = @course.enroll_user(@user)
      post 'enrollment_invitation', :course_id => @course.id, :accept => '1', :invitation => @enrollment.uuid
      response.should be_redirect
      response.should redirect_to(registration_confirmation_url(@pseudonym.communication_channel.confirmation_code, :enrollment => @enrollment.uuid))
    end

    it "should defer to registration_confirmation if logged-in user does not match enrollment user" do
      user_with_pseudonym
      @u2 = @user
      course_with_student_logged_in(:active_course => true, :active_user => true)
      @e2 = @course.enroll_user(@u2)
      post 'enrollment_invitation', :course_id => @course.id, :accept => '1', :invitation => @e2.uuid
      response.should redirect_to(registration_confirmation_url(:nonce => @pseudonym.communication_channel.confirmation_code, :enrollment => @e2.uuid))
    end
  end
  
  describe "GET 'show'" do
    it "should require authorization" do
      course_with_teacher(:active_all => true)
      get 'show', :id => @course.id
      assert_unauthorized
    end
    
    it "should assign variables" do
      course_with_student_logged_in(:active_all => true)
      get 'show', :id => @course.id
      response.should be_success
      assigns[:context].should eql(@course)
      # assigns[:message_types].should_not be_nil
    end

    it "should give a helpful error message for students that can't access yet" do
      course_with_student_logged_in(:active_all => true)
      @course.workflow_state = 'claimed'
      @course.save!
      get 'show', :id => @course.id
      response.status.should == '401 Unauthorized'
      assigns[:unauthorized_message].should_not be_nil

      @course.workflow_state = 'available'
      @course.save!
      @enrollment.start_at = 2.days.from_now
      @enrollment.end_at = 4.days.from_now
      @enrollment.save!
      get 'show', :id => @course.id
      response.status.should == '401 Unauthorized'
      assigns[:unauthorized_message].should_not be_nil
    end
    
    context "show feedback for the current course only on course front page" do
      before(:each) do
        course_with_student_logged_in(:active_all => true)
        @course1 = @course
        course_with_teacher(:course => @course1)
        
        course_with_student_logged_in(:active_all => true, :user => @student)
        @course2 = @course
        course_with_teacher(:course => @course1, :user => @teacher)
        
        @a1 = @course1.assignments.new(:title => "some assignment course 1")
        @a1.workflow_state = "published"
        @a1.save
        @s1 = @a1.submit_homework(@student)
        @c1 = @s1.add_comment(:author => @teacher, :comment => "some comment1")
        
        @a2 = @course2.assignments.new(:title => "some assignment course 2")
        @a2.workflow_state = "published"
        @a2.save
        @s2 = @a2.submit_homework(@student)
        @c2 = @s2.add_comment(:author => @teacher, :comment => "some comment2")
      end
      
      it "should work for module view" do 
        @course1.default_view = "modules"
        @course1.save
        get 'show', :id => @course1.id
        assigns(:recent_feedback).count.should == 1
        assigns(:recent_feedback).first.assignment_id.should == @a1.id
      end
      
      it "should work for assignments view" do 
        @course1.default_view = "assignments"
        @course1.save
        get 'show', :id => @course1.id
        assigns(:recent_feedback).count.should == 1
        assigns(:recent_feedback).first.assignment_id.should == @a1.id
      end
      
      it "should work for wiki view" do 
        @course1.default_view = "wiki"
        @course1.save
        get 'show', :id => @course1.id
        assigns(:recent_feedback).count.should == 1
        assigns(:recent_feedback).first.assignment_id.should == @a1.id
      end
      
      it "should work for syllabus view" do 
        @course1.default_view = "syllabus"
        @course1.save
        get 'show', :id => @course1.id
        assigns(:recent_feedback).count.should == 1
        assigns(:recent_feedback).first.assignment_id.should == @a1.id
      end
      
      it "should work for feed view" do 
        @course1.default_view = "feed"
        @course1.save
        get 'show', :id => @course1.id
        assigns(:recent_feedback).count.should == 1
        assigns(:recent_feedback).first.assignment_id.should == @a1.id
      end
      
    end

    context "invitations" do
      it "should allow an invited user to see the course" do
        course_with_student(:active_course => 1)
        @enrollment.should be_invited
        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.should be_success
        assigns[:pending_enrollment].should == @enrollment
      end

      it "should re-invite an enrollment that has previously been rejected" do
        course_with_student(:active_course => 1)
        @enrollment.should be_invited
        @enrollment.reject!
        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.should be_success
        @enrollment.reload
        @enrollment.should be_invited
      end

      it "should auto-accept if previews are not allowed" do
        # Currently, previews are only allowed for the default account
        @account = Account.create!
        course_with_student_logged_in(:active_course => 1, :account => @account)
        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.should be_success
        response.should render_template('show')
        assigns[:pending_enrollment].should be_nil
        assigns[:context_enrollment].should == @enrollment
        @enrollment.reload
        @enrollment.should be_active
      end

      it "should ignore invitations that have been accepted" do
        course_with_student(:active_course => 1, :active_enrollment => 1)
        @course.grants_right?(@user, nil, :read).should be_true
        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.status.should == '401 Unauthorized'

        # Force reload permissions
        controller.instance_variable_set(:@context_all_permissions, nil)
        user_session(@user)
        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.should be_success
        assigns[:pending_enrollment].should be_nil
      end

      it "should use the invitation enrollment, rather than the current enrollment" do
        course_with_student_logged_in(:active_course => 1, :active_user => 1)
        @student1 = @student
        @enrollment1 = @enrollment
        student_in_course
        @enrollment.should be_invited

        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.should be_success
        assigns[:pending_enrollment].should == @enrollment
        assigns[:current_user].should == @student1
        session[:enrollment_uuid].should == @enrollment.uuid
        @enrollment.reload
        @enrollment.should be_invited

        get 'show', :id => @course.id # invitation should be in the session now
        response.should be_success
        assigns[:pending_enrollment].should == @enrollment
        assigns[:current_user].should == @student1
        session[:enrollment_uuid].should == @enrollment.uuid
        @enrollment.reload
        @enrollment.should be_invited
      end

      it "should auto-redirect to registration page when it's a self-enrollment" do
        course_with_student(:active_course => 1)
        @user = User.new
        @user.communication_channels.build(:path => "jt@instructure.com")
        @user.workflow_state = 'creation_pending'
        @user.save!
        @enrollment = @course.enroll_student(@user)
        @enrollment.update_attribute(:self_enrolled, true)
        @enrollment.should be_invited

        get 'show', :id => @course.id, :invitation => @enrollment.uuid
        response.should redirect_to(registration_confirmation_url(@user.email_channel.confirmation_code, :enrollment => @enrollment.uuid))
      end

      it "should not use the session enrollment if it's for the wrong course" do
        course_with_student(:active_course => 1)
        @enrollment1 = @enrollment
        @course1 = @course
        course(:active_course => 1)
        student_in_course(:user => @user)
        @enrollment2 = @enrollment
        @course2 = @course
        user_session(@user)

        get 'show', :id => @course1.id
        response.should be_success
        assigns[:pending_enrollment].should == @enrollment1
        session[:enrollment_uuid].should == @enrollment1.uuid

        controller.instance_variable_set(:@pending_enrollment, nil)
        get 'show', :id => @course2.id
        response.should be_success
        assigns[:pending_enrollment].should == @enrollment2
        session[:enrollment_uuid].should == @enrollment2.uuid
      end
    end
  end
  
  describe "POST 'unenroll'" do
    it "should require authorization" do
      course_with_teacher(:active_all => true)
      post 'unenroll_user', :course_id => @course.id, :id => @enrollment.id
      assert_unauthorized
    end
    
    it "should not allow students to unenroll" do
      course_with_student_logged_in(:active_all => true)
      post 'unenroll_user', :course_id => @course.id, :id => @enrollment.id
      assert_unauthorized
    end
    
    it "should unenroll users" do
      course_with_teacher_logged_in(:active_all => true)
      student_in_course
      post 'unenroll_user', :course_id => @course.id, :id => @enrollment.id
      @course.reload
      response.should be_success
      @course.enrollments.map{|e| e.user}.should_not be_include(@student)
    end

    it "should not allow teachers to unenroll themselves" do
      course_with_teacher_logged_in(:active_all => true)
      post 'unenroll_user', :course_id => @course.id, :id => @enrollment.id
      assert_unauthorized
    end

    it "should allow admins to unenroll themselves" do
      course_with_teacher_logged_in(:active_all => true)
      @course.account.add_user(@teacher)
      post 'unenroll_user', :course_id => @course.id, :id => @enrollment.id
      @course.reload
      response.should be_success
      @course.enrollments.map{|e| e.user}.should_not be_include(@teacher)
    end
  end
  
  describe "POST 'enroll_users'" do
    before :each do
      account = Account.default
      account.settings = { :open_registration => true }
      account.save!
    end

    it "should require authorization" do
      course_with_teacher(:active_all => true)
      post 'enroll_users', :course_id => @course.id, :user_list => "sam@yahoo.com"
      assert_unauthorized
    end
    
    it "should not allow students to enroll people" do
      course_with_student_logged_in(:active_all => true)
      post 'enroll_users', :course_id => @course.id, :user_list => "\"Sam\" <sam@yahoo.com>, \"Fred\" <fred@yahoo.com>"
      assert_unauthorized
    end
    
    it "should enroll people" do
      course_with_teacher_logged_in(:active_all => true)
      post 'enroll_users', :course_id => @course.id, :user_list => "\"Sam\" <sam@yahoo.com>, \"Fred\" <fred@yahoo.com>"
      response.should be_success
      @course.reload
      @course.students.map{|s| s.name}.should be_include("Sam")
      @course.students.map{|s| s.name}.should be_include("Fred")
    end

    it "should allow TAs to enroll Observers (by default)" do
      course_with_teacher(:active_all => true)
      @user = user
      @course.enroll_ta(user).accept!
      user_session(@user)
      post 'enroll_users', :course_id => @course.id, :user_list => "\"Sam\" <sam@yahoo.com>, \"Fred\" <fred@yahoo.com>", :enrollment_type => 'ObserverEnrollment'
      response.should be_success
      @course.reload
      @course.students.should be_empty
      @course.observers.map{|s| s.name}.should be_include("Sam")
      @course.observers.map{|s| s.name}.should be_include("Fred")
    end
    
  end
  
  describe "PUT 'update'" do
    it "should require authorization" do
      course_with_teacher(:active_all => true)
      put 'update', :id => @course.id, :course => {:name => "new course name"}
      assert_unauthorized
    end
    
    it "should not let students update the course details" do
      course_with_student_logged_in(:active_all => true)
      put 'update', :id => @course.id, :course => {:name => "new course name"}
      assert_unauthorized
    end
    
    it "should update course details" do
      course_with_teacher_logged_in(:active_all => true)
      put 'update', :id => @course.id, :course => {:name => "new course name"}
      assigns[:course].should_not be_nil
      assigns[:course].should eql(@course)
    end
    
    it "should allow sending events" do
      course_with_teacher_logged_in(:active_all => true)
      put 'update', :id => @course.id, :course => {:event => "complete"}
      assigns[:course].should_not be_nil
      assigns[:course].state.should eql(:completed)
    end
  end

  describe "POST unconclude" do
    it "should unconclude the course" do
      course_with_teacher_logged_in(:active_all => true)
      delete 'destroy', :id => @course.id, :event => 'conclude'
      response.should be_redirect
      @course.reload.should be_completed
      @course.conclude_at.should <= Time.now

      post 'unconclude', :course_id => @course.id
      response.should be_redirect
      @course.reload.should be_available
      @course.conclude_at.should be_nil
    end
  end

  describe "GET 'self_enrollment'" do
    before do
      Account.default.update_attribute(:settings, :self_enrollment => 'any', :open_registration => true)
    end

    it "should enroll the currently logged in user" do
      course(:active_all => true)
      @course.update_attribute(:self_enrollment, true)
      user
      user_session(@user)

      get 'self_enrollment', :course_id => @course.id, :self_enrollment => @course.self_enrollment_code
      response.should redirect_to(course_url(@course))
      flash[:notice].should_not be_empty
      @user.enrollments.length.should == 1
      @enrollment = @user.enrollments.first
      @enrollment.course.should == @course
      @enrollment.workflow_state.should == 'active'
      @enrollment.should be_self_enrolled
    end

    it "should not enroll for incorrect code" do
      course(:active_all => true)
      @course.update_attribute(:self_enrollment, true)
      user
      user_session(@user)

      get 'self_enrollment', :course_id => @course.id, :self_enrollment => 'abc'
      response.should redirect_to(course_url(@course))
      @user.enrollments.length.should == 0
    end

    it "should not enroll if self_enrollment is disabled" do
      course(:active_all => true)
      user
      user_session(@user)

      get 'self_enrollment', :course_id => @course.id, :self_enrollment => @course.self_enrollment_code
      response.should redirect_to(course_url(@course))
      @user.enrollments.length.should == 0
    end

    it "should redirect to login without open registration" do
      Account.default.update_attribute(:settings, :open_registration => false)
      course(:active_all => true)
      @course.update_attribute(:self_enrollment, true)

      get 'self_enrollment', :course_id => @course.id, :self_enrollment => @course.self_enrollment_code
      response.should redirect_to(login_url)
    end

    it "should render for non-logged-in user" do
      course(:active_all => true)
      @course.update_attribute(:self_enrollment, true)

      get 'self_enrollment', :course_id => @course.id, :self_enrollment => @course.self_enrollment_code
      response.should be_success
      response.should render_template('open_enrollment')
    end

    it "should create a creation_pending user" do
      course(:active_all => true)
      @course.update_attribute(:self_enrollment, true)

      post 'self_enrollment', :course_id => @course.id, :self_enrollment => @course.self_enrollment_code, :email => 'bracken@instructure.com'
      response.should be_success
      response.should render_template('open_enrollment_confirmed')
      @course.student_enrollments.length.should == 1
      @enrollment = @course.student_enrollments.first
      @enrollment.should be_self_enrolled
      @enrollment.should be_invited
      @enrollment.user.should be_creation_pending
      @enrollment.user.email_channel.path.should == 'bracken@instructure.com'
      @enrollment.user.email_channel.should be_unconfirmed
      @enrollment.user.pseudonyms.should be_empty
    end
  end

  describe "GET 'self_unenrollment'" do
    it "should unenroll" do
      course_with_student_logged_in(:active_all => true)
      @enrollment.update_attribute(:self_enrolled, true)

      get 'self_unenrollment', :course_id => @course.id, :self_unenrollment => @enrollment.uuid
      response.should redirect_to(course_url(@course))
      @enrollment.reload
      @enrollment.should be_completed
    end

    it "should not unenroll for incorrect code" do
      course_with_student_logged_in(:active_all => true)
      @enrollment.update_attribute(:self_enrolled, true)

      get 'self_unenrollment', :course_id => @course.id, :self_unenrollment => 'abc'
      response.should redirect_to(course_url(@course))
      @enrollment.reload
      @enrollment.should be_active
    end

    it "should not unenroll a non-self-enrollment" do
      course_with_student_logged_in(:active_all => true)

      get 'self_unenrollment', :course_id => @course.id, :self_unenrollment => @enrollment.uuid
      response.should redirect_to(course_url(@course))
      @enrollment.reload
      @enrollment.should be_active
    end
  end
end
