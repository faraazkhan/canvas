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

require File.expand_path(File.dirname(__FILE__) + '/../api_spec_helper')

describe SubmissionsApiController, :type => :integration do

  def submit_homework(assignment, student, opts = {:body => "test!"})
    @submit_homework_time ||= Time.zone.at(0)
    @submit_homework_time += 1.hour
    sub = assignment.find_or_create_submission(student)
    if sub.versions.size == 1
      Version.update_all({:created_at => @submit_homework_time}, {:id => sub.versions.first.id})
    end
    sub.workflow_state = 'submitted'
    yield(sub) if block_given?
    sub.with_versioning(:explicit => true) do
      update_with_protected_attributes!(sub, { :submitted_at => @submit_homework_time, :created_at => @submit_homework_time }.merge(opts))
    end
    sub.versions(true).each { |v| Version.update_all({ :created_at => v.model.created_at }, { :id => v.id }) }
    sub
  end

  it "should not 404 if there is no submission" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    @assignment = @course.assignments.create!(:title => 'assignment1', :grading_type => 'points', :points_possible => 12)
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :include => %w(submission_history submission_comments rubric_assessment) })
    json.should == {
      "assignment_id" => @assignment.id,
      "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}?preview=1",
      "user_id"=>student.id,
      "grade"=>nil,
      "body"=>nil,
      "submitted_at"=>nil,
      "submission_history"=>[],
      "attempt"=>nil,
      "url"=>nil,
      "submission_type"=>nil,
      "submission_comments"=>[],
      "grade_matches_current_submission"=>nil,
      "score"=>nil
    }
  end

  describe "using section ids" do
    before do
      @student1 = user(:active_all => true)
      course_with_teacher(:active_all => true)
      @default_section = @course.default_section
      @section = factory_with_protected_attributes(@course.course_sections, :sis_source_id => 'my-section-sis-id', :name => 'section2')
      @course.enroll_user(@student1, 'StudentEnrollment', :section => @section).accept!

      quiz = Quiz.create!(:title => 'quiz1', :context => @course)
      quiz.did_edit!
      quiz.offer!
      @a1 = quiz.assignment
      sub = @a1.find_or_create_submission(@student1)
      sub.submission_type = 'online_quiz'
      sub.workflow_state = 'submitted'
      sub.save!
    end

    it "should list submissions" do
      json = api_call(:get,
            "/api/v1/sections/#{@default_section.id}/assignments/#{@a1.id}/submissions.json",
            { :controller => 'submissions_api', :action => 'index',
              :format => 'json', :section_id => @default_section.id.to_s,
              :assignment_id => @a1.id.to_s },
            { :include => %w(submission_history submission_comments rubric_assessment) })
      json.size.should == 0

      json = api_call(:get,
            "/api/v1/sections/sis_section_id:my-section-sis-id/assignments/#{@a1.id}/submissions.json",
            { :controller => 'submissions_api', :action => 'index',
              :format => 'json', :section_id => 'sis_section_id:my-section-sis-id',
              :assignment_id => @a1.id.to_s },
            { :include => %w(submission_history submission_comments rubric_assessment) })
      json.size.should == 1
      json.first['user_id'].should == @student1.id

      json = api_call(:get,
            "/api/v1/sections/#{@default_section.id}/students/submissions",
            { :controller => 'submissions_api', :action => 'for_students',
              :format => 'json', :section_id => @default_section.id.to_s },
              :student_ids => [@student1.id])
      json.size.should == 0

      json = api_call(:get,
            "/api/v1/sections/sis_section_id:my-section-sis-id/students/submissions",
            { :controller => 'submissions_api', :action => 'for_students',
              :format => 'json', :section_id => 'sis_section_id:my-section-sis-id' },
              :student_ids => [@student1.id])
      json.size.should == 1
    end

    it "should post to submissions" do
      @a1 = @course.assignments.create!({:title => 'assignment1', :grading_type => 'percent', :points_possible => 10})
      raw_api_call(:put,
                      "/api/v1/sections/#{@default_section.id}/assignments/#{@a1.id}/submissions/#{@student1.id}",
      { :controller => 'submissions_api', :action => 'update',
        :format => 'json', :section_id => @default_section.id.to_s,
        :assignment_id => @a1.id.to_s, :id => @student1.id.to_s },
        { :submission => { :posted_grade => '75%' } })
      response.status.should == "404 Not Found"

      json = api_call(:put,
                      "/api/v1/sections/sis_section_id:my-section-sis-id/assignments/#{@a1.id}/submissions/#{@student1.id}",
      { :controller => 'submissions_api', :action => 'update',
        :format => 'json', :section_id => 'sis_section_id:my-section-sis-id',
        :assignment_id => @a1.id.to_s, :id => @student1.id.to_s },
        { :submission => { :posted_grade => '75%' } })

      Submission.count.should == 2
      @submission = Submission.last(:order => :id)

      json['score'].should == 7.5
      json['grade'].should == '75%'
    end

    it "should return submissions for a section" do
      json = api_call(:get,
            "/api/v1/sections/sis_section_id:my-section-sis-id/assignments/#{@a1.id}/submissions/#{@student1.id}",
            { :controller => 'submissions_api', :action => 'show',
              :format => 'json', :section_id => 'sis_section_id:my-section-sis-id',
              :assignment_id => @a1.id.to_s, :id => @student1.id.to_s },
            { :include => %w(submission_history submission_comments rubric_assessment) })
      json['user_id'].should == @student1.id
    end

    it "should not find sections in other root accounts" do
      acct = account_model(:name => 'other root')
      @first_course = @course
      course(:active_all => true, :account => acct)
      @course.default_section.update_attribute('sis_source_id', 'my-section-sis-id')
      json = api_call(:get,
            "/api/v1/sections/sis_section_id:my-section-sis-id/assignments/#{@a1.id}/submissions",
            { :controller => 'submissions_api', :action => 'index',
              :format => 'json', :section_id => 'sis_section_id:my-section-sis-id',
              :assignment_id => @a1.id.to_s })
      json.size.should == 1 # should find the submission for @first_course
      @course.default_section.update_attribute('sis_source_id', 'section-2')
      raw_api_call(:get,
            "/api/v1/sections/sis_section_id:section-2/assignments/#{@a1.id}/submissions",
            { :controller => 'submissions_api', :action => 'index',
              :format => 'json', :section_id => 'sis_section_id:section-2',
              :assignment_id => @a1.id.to_s })
      response.status.should == "404 Not Found" # rather than 401 unauthorized
    end
  end

  it "should return student discussion entries for discussion_topic assignments" do
    @student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(@student).accept!
    @context = @course
    @assignment = factory_with_protected_attributes(@course.assignments, {:title => 'assignment1', :submission_types => 'discussion_topic', :discussion_topic => discussion_topic_model})

    e1 = @topic.discussion_entries.create!(:message => 'main entry', :user => @user)
    se1 = @topic.discussion_entries.create!(:message => 'sub 1', :user => @student, :parent_entry => e1)
    @assignment.submit_homework(@student, :submission_type => 'discussion_topic')
    se2 = @topic.discussion_entries.create!(:message => 'student 1', :user => @student)
    @assignment.submit_homework(@student, :submission_type => 'discussion_topic')
    e1 = @topic.discussion_entries.create!(:message => 'another entry', :user => @user)

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{@student.id}.json",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => @student.id.to_s })

    json['discussion_entries'].sort_by { |h| h['user_id'] }.should ==
      [{
        'message' => 'sub 1',
        'user_id' => @student.id,
        'created_at' => se1.created_at.as_json,
        'updated_at' => se1.updated_at.as_json,
      },
      {
        'message' => 'student 1',
        'user_id' => @student.id,
        'created_at' => se2.created_at.as_json,
        'updated_at' => se2.updated_at.as_json,
      }].sort_by { |h| h['user_id'] }

    # don't include discussion entries if response_fields limits the response
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{@student.id}",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => @student.id.to_s },
          { :response_fields => SubmissionsApiController::SUBMISSION_JSON_FIELDS })
    json['discussion_entries'].should be_nil

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{@student.id}",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => @student.id.to_s },
          { :exclude_response_fields => %w(discussion_entries) })
    json['discussion_entries'].should be_nil
  end

  it "should return student discussion entries from child topics for discussion_topic group assignments" do
    @student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(@student).accept!
    group_category = @course.group_categories.create(:name => "Category")
    @group = @course.groups.create(:name => "Group", :group_category => group_category)
    @group.add_user(@student)
    @context = @course
    @assignment = factory_with_protected_attributes(@course.assignments, {:title => 'assignment1', :submission_types => 'discussion_topic', :discussion_topic => discussion_topic_model, :group_category => @group.group_category})
    @topic.refresh_subtopics # since the DJ won't happen in time
    @child_topic = @group.discussion_topics.find_by_root_topic_id(@topic.id)

    e1 = @child_topic.discussion_entries.create!(:message => 'main entry', :user => @user)
    se1 = @child_topic.discussion_entries.create!(:message => 'sub 1', :user => @student, :parent_entry => e1)
    @assignment.submit_homework(@student, :submission_type => 'discussion_topic')
    se2 = @child_topic.discussion_entries.create!(:message => 'student 1', :user => @student)
    @assignment.submit_homework(@student, :submission_type => 'discussion_topic')
    e1 = @child_topic.discussion_entries.create!(:message => 'another entry', :user => @user)

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{@student.id}.json",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => @student.id.to_s })

    json['discussion_entries'].sort_by { |h| h['user_id'] }.should ==
      [{
        'message' => 'sub 1',
        'user_id' => @student.id,
        'created_at' => se1.created_at.as_json,
        'updated_at' => se1.updated_at.as_json,
      },
      {
        'message' => 'student 1',
        'user_id' => @student.id,
        'created_at' => se2.created_at.as_json,
        'updated_at' => se2.updated_at.as_json,
      }].sort_by { |h| h['user_id'] }
  end

  it "should return a valid preview url for quiz submissions" do
    student1 = user(:active_all => true)
    course_with_teacher_logged_in(:active_all => true) # need to be logged in to view the preview url below
    @course.enroll_student(student1).accept!
    quiz = Quiz.create!(:title => 'quiz1', :context => @course)
    quiz.did_edit!
    quiz.offer!
    a1 = quiz.assignment
    sub = a1.find_or_create_submission(student1)
    sub.submission_type = 'online_quiz'
    sub.workflow_state = 'submitted'
    sub.save!

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions.json",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s },
          { :include => %w(submission_history submission_comments rubric_assessment) })

    get_via_redirect json.first['preview_url']
    response.should be_success
    response.body.should match(/Redirecting to quiz page/)
  end

  it "should allow students to retrieve their own submission" do
    student1 = user(:active_all => true)
    student2 = user(:active_all => true)

    course_with_teacher(:active_all => true)

    @course.enroll_student(student1).accept!
    @course.enroll_student(student2).accept!

    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    sub1 = submit_homework(a1, student1)
    media_object(:media_id => "3232", :media_type => "audio")
    a1.grade_student(student1, {:grade => '90%', :comment => "Well here's the thing...", :media_comment_id => "3232", :media_comment_type => "audio"})
    comment = sub1.submission_comments.first

    @user = student1
    json = api_call(:get,
                    "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}.json",
                    { :controller => "submissions_api", :action => "show",
                      :format => "json", :course_id => @course.id.to_s,
                      :assignment_id => a1.id.to_s, :id => student1.id.to_s },
                    { :include => %w(submission_comments) })

    json.should == {"grade"=>"A-",
        "body"=>"test!",
        "assignment_id" => a1.id,
        "submitted_at"=>"1970-01-01T01:00:00Z",
        "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}?preview=1",
        "grade_matches_current_submission"=>true,
        "attempt"=>1,
        "url"=>nil,
        "submission_type"=>"online_text_entry",
        "user_id"=>student1.id,
        "submission_comments"=>
         [{"comment"=>"Well here's the thing...",
           "media_comment" => {
             "media_id"=>"3232",
             "media_type"=>"audio",
             "content-type" => "audio/mp4",
             "url" => "http://www.example.com/users/#{@user.id}/media_download?entryId=3232&redirect=1&type=mp4",
             "display_name" => nil
           },
           "created_at"=>comment.created_at.as_json,
           "author_name"=>"User",
           "author_id"=>student1.id}],
        "score"=>13.5}

    # can't access other students' submissions
    @user = student2
    raw_api_call(:get,
                    "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}.json",
                    { :controller => "submissions_api", :action => "show",
                      :format => "json", :course_id => @course.id.to_s,
                      :assignment_id => a1.id.to_s, :id => student1.id.to_s },
                    { :include => %w(submission_comments) })
    response.status.should =~ /401/
    JSON.parse(response.body).should == { 'status' => 'unauthorized' }
  end

  it "should allow retrieving attachments without a session" do
    student1 = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student1).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    sub1 = submit_homework(a1, student1) { |s| s.attachments = [attachment_model(:uploaded_data => stub_png_data, :content_type => 'image/png', :context => student1)] }
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions.json",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s },
          { :include => %w(submission_history submission_comments rubric_assessment) })
    url = json[0]['attachments'][0]['url']
    get_via_redirect(url)
    response.should be_success
    response['content-type'].should == 'image/png'
  end

  it "should allow retrieving media comments without a session" do
    student1 = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student1).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    media_object(:media_id => "54321", :context => student1, :user => student1)
    mock_kaltura = mock('Kaltura::ClientV3')
    Kaltura::ClientV3.stubs(:new).returns(mock_kaltura)
    mock_kaltura.expects :startSession
    mock_kaltura.expects(:flavorAssetGetByEntryId).returns([{:fileExt => 'mp4', :id => 'fake'}])
    mock_kaltura.expects(:flavorAssetGetDownloadUrl).returns("https://kaltura.example.com/some/url")
    submit_homework(a1, student1, :media_comment_id => "54321", :media_comment_type => "video")
    stub_kaltura
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions.json",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s },
          { :include => %w(submission_history submission_comments rubric_assessment) })
    url = json[0]['media_comment']['url']
    get(url)
    response.should be_redirect
    response['Location'].should match(%r{https://kaltura.example.com/some/url})
  end

  it "should return all submissions for an assignment" do
    student1 = user(:active_all => true)
    student2 = user(:active_all => true)

    course_with_teacher(:active_all => true)

    @course.enroll_student(student1).accept!
    @course.enroll_student(student2).accept!

    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    rubric = rubric_model(:user => @user, :context => @course,
                          :data => larger_rubric_data)
    a1.create_rubric_association(:rubric => rubric, :purpose => 'grading', :use_for_grading => true)

    submit_homework(a1, student1)
    media_object(:media_id => "54321", :context => student1, :user => student1)
    submit_homework(a1, student1, :media_comment_id => "54321", :media_comment_type => "video")
    sub1 = submit_homework(a1, student1) { |s| s.attachments = [attachment_model(:context => student1, :folder => nil)] }

    sub2 = submit_homework(a1, student2, :url => "http://www.instructure.com") { |s| s.attachment = attachment_model(:context => s, :filename => 'snapshot.png', :content_type => 'image/png'); s.attachments = [attachment_model(:context => a1, :filename => 'ss2.png', :content_type => 'image/png')] }

    media_object(:media_id => "3232", :context => student1, :user => student1, :media_type => "audio")
    a1.grade_student(student1, {:grade => '90%', :comment => "Well here's the thing...", :media_comment_id => "3232", :media_comment_type => "audio"})
    sub1.reload
    sub1.submission_comments.size.should == 1
    comment = sub1.submission_comments.first
    ra = a1.rubric_association.assess(
          :assessor => @user, :user => student2, :artifact => sub2,
          :assessment => {:assessment_type => 'grading', :criterion_crit1 => { :points => 7 }, :criterion_crit2 => { :points => 2, :comments => 'Hmm'}})

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions.json",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s },
          { :include => %w(submission_history submission_comments rubric_assessment) })

    res =
      [{"grade"=>"A-",
        "body"=>"test!",
        "assignment_id" => a1.id,
        "submitted_at"=>"1970-01-01T03:00:00Z",
        "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}?preview=1",
        "grade_matches_current_submission"=>true,
        "attachments" =>
         [
           { "content-type" => "application/loser",
             "url" => "http://www.example.com/files/#{sub1.attachments.first.id}/download?verifier=#{sub1.attachments.first.uuid}",
             "filename" => "unknown.loser",
             "display_name" => "unknown.loser" },
         ],
        "submission_history"=>
         [{"grade"=>nil,
           "body"=>"test!",
           "assignment_id" => a1.id,
           "submitted_at"=>"1970-01-01T01:00:00Z",
           "attempt"=>1,
           "url"=>nil,
           "submission_type"=>"online_text_entry",
           "user_id"=>student1.id,
           "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}?preview=1&version=0",
           "grade_matches_current_submission"=>nil,
           "score"=>nil},
          {"grade"=>nil,
            "assignment_id" => a1.id,
           "media_comment" =>
            { "media_type"=>"video",
              "media_id"=>"54321",
              "content-type" => "video/mp4",
              "url" => "http://www.example.com/users/#{@user.id}/media_download?entryId=54321&redirect=1&type=mp4",
              "display_name" => nil },
           "body"=>"test!",
           "submitted_at"=>"1970-01-01T02:00:00Z",
           "attempt"=>2,
           "url"=>nil,
           "submission_type"=>"online_text_entry",
           "user_id"=>student1.id,
           "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}?preview=1&version=1",
           "grade_matches_current_submission"=>nil,
           "score"=>nil},
          {"grade"=>"A-",
            "assignment_id" => a1.id,
           "media_comment" =>
            { "media_type"=>"video",
              "media_id"=>"54321","content-type" => "video/mp4",
              "url" => "http://www.example.com/users/#{@user.id}/media_download?entryId=54321&redirect=1&type=mp4",
              "display_name" => nil },
           "attachments" =>
            [
              { "content-type" => "application/loser",
                "url" => "http://www.example.com/files/#{sub1.attachments.first.id}/download?verifier=#{sub1.attachments.first.uuid}",
                "filename" => "unknown.loser",
                "display_name" => "unknown.loser" },
            ],
           "body"=>"test!",
           "submitted_at"=>"1970-01-01T03:00:00Z",
           "attempt"=>3,
           "url"=>nil,
           "submission_type"=>"online_text_entry",
           "user_id"=>student1.id,
           "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student1.id}?preview=1&version=2",
           "grade_matches_current_submission"=>true,
           "score"=>13.5}],
        "attempt"=>3,
        "url"=>nil,
        "submission_type"=>"online_text_entry",
        "user_id"=>student1.id,
        "submission_comments"=>
         [{"comment"=>"Well here's the thing...",
           "media_comment" => {
             "media_type"=>"audio",
             "media_id"=>"3232",
             "content-type" => "audio/mp4",
             "url" => "http://www.example.com/users/#{@user.id}/media_download?entryId=3232&redirect=1&type=mp4",
             "display_name" => nil
           },
           "created_at"=>comment.created_at.as_json,
           "author_name"=>"User",
           "author_id"=>student1.id}],
        "media_comment" =>
         { "media_type"=>"video",
           "media_id"=>"54321",
           "content-type" => "video/mp4",
           "url" => "http://www.example.com/users/#{@user.id}/media_download?entryId=54321&redirect=1&type=mp4",
           "display_name" => nil },
        "score"=>13.5},
       {"grade"=>"F",
        "assignment_id" => a1.id,
        "body"=>nil,
        "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student2.id}?preview=1",
        "grade_matches_current_submission"=>true,
        "submitted_at"=>"1970-01-01T04:00:00Z",
        "submission_history"=>
         [{"grade"=>"F",
           "assignment_id" => a1.id,
           "body"=>nil,
           "submitted_at"=>"1970-01-01T04:00:00Z",
           "attempt"=>1,
           "url"=>"http://www.instructure.com",
           "submission_type"=>"online_url",
           "user_id"=>student2.id,
           "preview_url" => "http://www.example.com/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student2.id}?preview=1&version=0",
          "grade_matches_current_submission"=>true,
           "attachments" =>
            [
             {"content-type" => "image/png",
              "display_name" => "ss2.png",
              "filename" => "ss2.png",
              "url" => "http://www.example.com/files/#{sub2.attachments.first.id}/download?verifier=#{sub2.attachments.first.uuid}",},
             {"content-type" => "image/png",
              "display_name" => "snapshot.png",
              "filename" => "snapshot.png",
              "url" => "http://www.example.com/files/#{sub2.attachment.id}/download?verifier=#{sub2.attachment.uuid}",},
            ],
           "score"=>9}],
        "attempt"=>1,
        "url"=>"http://www.instructure.com",
        "submission_type"=>"online_url",
        "user_id"=>student2.id,
        "attachments" =>
         [
          {"content-type" => "image/png",
           "display_name" => "ss2.png",
           "filename" => "ss2.png",
           "url" => "http://www.example.com/files/#{sub2.attachments.first.id}/download?verifier=#{sub2.attachments.first.uuid}",},
          {"content-type" => "image/png",
           "display_name" => "snapshot.png",
           "filename" => "snapshot.png",
           "url" => "http://www.example.com/files/#{sub2.attachment.id}/download?verifier=#{sub2.attachment.uuid}",},
         ],
        "submission_comments"=>[],
        "score"=>9,
        "rubric_assessment"=>
         {"crit2"=>{"comments"=>"Hmm", "points"=>2},
          "crit1"=>{"comments"=>nil, "points"=>7}}}]
    json.sort_by { |h| h['user_id'] }.should == res.sort_by { |h| h['user_id'] }
  end

  it "should return nothing if no assignments in the course" do
    student1 = user(:active_all => true)
    student2 = user_with_pseudonym(:active_all => true)
    student2.pseudonym.update_attribute(:sis_user_id, 'my-student-id')

    course_with_teacher(:active_all => true)

    @course.enroll_student(student1).accept!
    @course.enroll_student(student2).accept!

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param], :grouped => 1 })
    json.sort_by { |h| h['user_id'] }.should == [
      {
        'user_id' => student1.id,
        'submissions' => [],
      },
      {
        'user_id' => student2.id,
        'submissions' => [],
      },
    ]

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param] })
    json.should == []
  end

  it "should return turnitin data if present" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    a1.turnitin_settings = {:originality_report_visibility => 'after_grading'}
    a1.save!
    submission = submit_homework(a1, student)
    sample_turnitin_data = {
      :last_processed_attempt=>1,
      "attachment_504177"=> {
        :web_overlap=>73,
        :publication_overlap=>0,
        :error=>true,
        :student_overlap=>100,
        :state=>"failure",
        :similarity_score=>100,
        :object_id=>"123345"
      }
    }
    submission.turnitin_data = sample_turnitin_data
    submission.save!
    
    # as teacher
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s })
    json.should have_key 'turnitin_data'
    sample_turnitin_data.delete :last_processed_attempt
    json['turnitin_data'].should == sample_turnitin_data.with_indifferent_access
    
    # as student before graded
    @user = student
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s })
    json.should_not have_key 'turnitin_data'
    
    # as student after grading
    a1.grade_student(student, {:grade => 11})
    @user = student
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s })
    json.should have_key 'turnitin_data'
    json['turnitin_data'].should == sample_turnitin_data.with_indifferent_access
    
  end

  it "should return all submissions for a student" do
    student1 = user(:active_all => true)
    student2 = user_with_pseudonym(:active_all => true)
    student2.pseudonym.update_attribute(:sis_user_id, 'my-student-id')

    course_with_teacher(:active_all => true)

    @course.enroll_student(student1).accept!
    @course.enroll_student(student2).accept!

    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    a2 = @course.assignments.create!(:title => 'assignment2', :grading_type => 'letter_grade', :points_possible => 25)

    submit_homework(a1, student1)
    submit_homework(a2, student1)
    submit_homework(a1, student2)

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param] })

    json.size.should == 2
    json.each { |submission| submission['user_id'].should == student1.id }

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param] })

    json.size.should == 3

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param],
            :assignment_ids => [a1.to_param] })

    json.size.should == 2
    json.all? { |submission| submission['assignment_id'].should == a1.id }.should be_true

    # by sis user id!
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, 'sis_user_id:my-student-id'],
            :assignment_ids => [a1.to_param] })

    json.size.should == 2
    json.all? { |submission| submission['assignment_id'].should == a1.id }.should be_true

    # by sis login id!
    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, "sis_login_id:#{student2.pseudonym.unique_id}"],
            :assignment_ids => [a1.to_param] })

    json.size.should == 2
    json.all? { |submission| submission['assignment_id'].should == a1.id }.should be_true
  end

  it "should return student submissions grouped by student" do
    student1 = user(:active_all => true)
    student2 = user_with_pseudonym(:active_all => true)

    course_with_teacher(:active_all => true)

    @course.enroll_student(student1).accept!
    @course.enroll_student(student2).accept!

    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    a2 = @course.assignments.create!(:title => 'assignment2', :grading_type => 'letter_grade', :points_possible => 25)

    submit_homework(a1, student1)
    submit_homework(a2, student1)
    submit_homework(a1, student2)

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param], :grouped => '1' })

    json.size.should == 1
    json.first['submissions'].size.should == 2
    json.each { |user| user['user_id'].should == student1.id }

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param], :grouped => '1' })

    json.size.should == 2
    json.map { |u| u['submissions'] }.flatten.size.should == 3

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param],
            :assignment_ids => [a1.to_param], :grouped => '1' })

    json.size.should == 2
    json.each { |user| user['submissions'].each { |s| s['assignment_id'].should == a1.id } }
  end

  it "should return students with no submissions when grouped" do
    student1 = user(:active_all => true)
    student2 = user_with_pseudonym(:active_all => true)
    student2.pseudonym.update_attribute(:sis_user_id, 'my-student-id')

    course_with_teacher(:active_all => true)

    @course.enroll_student(student1).accept!
    @course.enroll_student(student2).accept!

    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    a2 = @course.assignments.create!(:title => 'assignment2', :grading_type => 'letter_grade', :points_possible => 25)

    submit_homework(a1, student1)
    submit_homework(a2, student1)

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions.json",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.to_param },
          { :student_ids => [student1.to_param, student2.to_param], :grouped => '1' })

    json.size.should == 2
    json.detect { |u| u['user_id'] == student1.id }['submissions'].size.should == 2
    json.detect { |u| u['user_id'] == student2.id }['submissions'].size.should == 0
  end

  it "should allow grading an uncreated submission" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :submission => { :posted_grade => 'B' } })

    Submission.count.should == 1
    @submission = Submission.first

    json['grade'].should == 'B'
    json['score'].should == 12.9
  end

  it "should allow posting grade by sis id" do
    student = user_with_pseudonym(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    @course.update_attribute(:sis_source_id, "my-course-id")
    student.pseudonym.update_attribute(:sis_user_id, "my-user-id")
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)

    json = api_call(:put,
          "/api/v1/courses/sis_course_id:my-course-id/assignments/#{a1.id}/submissions/sis_user_id:my-user-id.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => 'sis_course_id:my-course-id',
            :assignment_id => a1.id.to_s, :id => 'sis_user_id:my-user-id' },
          { :submission => { :posted_grade => 'B' } })

    Submission.count.should == 1
    @submission = Submission.first

    json['grade'].should == 'B'
    json['score'].should == 12.9
  end

  it "should allow commenting by a student without trying to grade" do
    course_with_teacher(:active_all => true)
    student = user(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)

    # since student is the most recently created user, @user = student, so this
    # call will happen as student
    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :comment => { :text_comment => 'witty remark' } })

    Submission.count.should == 1
    @submission = Submission.first
    @submission.submission_comments.size.should == 1
    comment = @submission.submission_comments.first
    comment.comment.should == 'witty remark'
    comment.author.should == student
  end

  it "should not allow grading by a student" do
    course_with_teacher(:active_all => true)
    student = user(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)

    # since student is the most recently created user, @user = student, so this
    # call will happen as student
    raw_api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :comment => { :text_comment => 'witty remark' },
            :submission => { :posted_grade => 'B' } })
    response.status.should == '401 Unauthorized'
  end

  it "should not allow rubricking by a student" do
    course_with_teacher(:active_all => true)
    student = user(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)

    # since student is the most recently created user, @user = student, so this
    # call will happen as student
    raw_api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :comment => { :text_comment => 'witty remark' },
            :rubric_assessment => { :criteria => { :points => 5 } } })
    response.status.should == '401 Unauthorized'
  end

  it "should not return submissions for no-longer-enrolled students" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    enrollment = @course.enroll_student(student)
    enrollment.accept!
    assignment = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    submit_homework(assignment, student)

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{assignment.id}/submissions.json",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => assignment.id.to_s })
    json.length.should == 1

    enrollment.destroy

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{assignment.id}/submissions.json",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => assignment.id.to_s })
    json.length.should == 0
  end

  it "should allow updating the grade for an existing submission" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)
    submission = a1.find_or_create_submission(student)
    submission.should_not be_new_record
    submission.grade = 'A'
    submission.save!

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :submission => { :posted_grade => 'B' } })

    Submission.count.should == 1
    @submission = Submission.first
    submission.id.should == @submission.id

    json['grade'].should == 'B'
    json['score'].should == 12.9
  end

  it "should allow submitting points" do
    submit_with_grade({ :grading_type => 'points', :points_possible => 15 }, '13.2', 13.2, '13.2')
  end

  it "should allow submitting points above points_possible (for extra credit)" do
    submit_with_grade({ :grading_type => 'points', :points_possible => 15 }, '16', 16, '16')
  end

  it "should allow submitting percent to a points assignment" do
    submit_with_grade({ :grading_type => 'points', :points_possible => 15 }, '50%', 7.5, '7.5')
  end

  it "should allow submitting percent" do
    submit_with_grade({ :grading_type => 'percent', :points_possible => 10 }, '75%', 7.5, "75%")
  end

  it "should allow submitting points to a percent assignment" do
    submit_with_grade({ :grading_type => 'percent', :points_possible => 10 }, '5', 5, "50%")
  end

  it "should allow submitting percent above points_possible (for extra credit)" do
    submit_with_grade({ :grading_type => 'percent', :points_possible => 10 }, '105%', 10.5, "105%")
  end

  it "should allow submitting letter_grade as a letter score" do
    submit_with_grade({ :grading_type => 'letter_grade', :points_possible => 15 }, 'B', 12.9, 'B')
  end

  it "should allow submitting letter_grade as a numeric score" do
    submit_with_grade({ :grading_type => 'letter_grade', :points_possible => 15 }, '11.9', 11.9, 'C+')
  end

  it "should allow submitting letter_grade as a percentage score" do
    submit_with_grade({ :grading_type => 'letter_grade', :points_possible => 15 }, '70%', 10.5, 'C-')
  end

  it "should reject letter grades sent to a points assignment" do
    submit_with_grade({ :grading_type => 'points', :points_possible => 15 }, 'B-', nil, nil)
  end

  it "should allow submitting pass_fail (pass)" do
    submit_with_grade({ :grading_type => 'pass_fail', :points_possible => 12 }, 'pass', 12, "complete")
  end

  it "should allow submitting pass_fail (fail)" do
    submit_with_grade({ :grading_type => 'pass_fail', :points_possible => 12 }, 'fail', 0, "incomplete")
  end

  it "should allow a points score for pass_fail, at full points" do
    submit_with_grade({ :grading_type => 'pass_fail', :points_possible => 12 }, '12', 12, "complete")
  end

  it "should allow a points score for pass_fail, at zero points" do
    submit_with_grade({ :grading_type => 'pass_fail', :points_possible => 12 }, '0', 0, "incomplete")
  end

  it "should allow a percentage score for pass_fail, at full points" do
    submit_with_grade({ :grading_type => 'pass_fail', :points_possible => 12 }, '100%', 12, "complete")
  end

  it "should reject any other type of score for a pass_fail assignment" do
    submit_with_grade({ :grading_type => 'pass_fail', :points_possible => 12 }, '50%', nil, nil)
  end

  def submit_with_grade(assignment_opts, param, score, grade)
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!({:title => 'assignment1'}.merge(assignment_opts))

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :submission => { :posted_grade => param } })

    Submission.count.should == 1
    @submission = Submission.first

    json['score'].should == score
    json['grade'].should == grade
  end

  it "should allow posting a rubric assessment" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'points', :points_possible => 12)
    rubric = rubric_model(:user => @user, :context => @course,
                          :data => larger_rubric_data)
    a1.create_rubric_association(:rubric => rubric, :purpose => 'grading', :use_for_grading => true)

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :rubric_assessment =>
             { :crit1 => { :points => 7 },
               :crit2 => { :points => 2, :comments => 'Rock on' } } })

    Submission.count.should == 1
    @submission = Submission.first
    @submission.user_id.should == student.id
    @submission.score.should == 9
    @submission.rubric_assessment.should_not be_nil
    @submission.rubric_assessment.data.should ==
      [{:description=>"B",
        :criterion_id=>"crit1",
        :comments_enabled=>true,
        :points=>7,
        :learning_outcome_id=>nil,
        :id=>"rat2",
        :comments=>nil},
      {:description=>"Pass",
        :criterion_id=>"crit2",
        :comments_enabled=>true,
        :points=>2,
        :learning_outcome_id=>nil,
        :id=>"rat1",
        :comments=>"Rock on"}]
  end

  it "should allow posting a comment on a submission" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    @assignment = @course.assignments.create!(:title => 'assignment1', :grading_type => 'points', :points_possible => 12)
    submit_homework(@assignment, student)

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :comment =>
            { :text_comment => "ohai!" } })

    Submission.count.should == 1
    @submission = Submission.first
    json['submission_comments'].size.should == 1
    json['submission_comments'].first['comment'].should == 'ohai!'
  end

  it "should allow posting a media comment on a submission, given a kaltura id" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    @assignment = @course.assignments.create!(:title => 'assignment1', :grading_type => 'points', :points_possible => 12)
    media_object(:media_id => "1234", :media_type => 'audio')

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :comment =>
            { :media_comment_id => '1234', :media_comment_type => 'audio' } })

    Submission.count.should == 1
    @submission = Submission.first
    json['submission_comments'].size.should == 1
    comment = json['submission_comments'].first
    comment['comment'].should == 'This is a media comment.'
    comment['media_comment']['url'].should == "http://www.example.com/users/#{@user.id}/media_download?entryId=1234&redirect=1&type=mp4"
    comment['media_comment']["content-type"].should == "audio/mp4"
  end

  it "should allow commenting on an uncreated submission" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    a1 = @course.assignments.create!(:title => 'assignment1', :grading_type => 'letter_grade', :points_possible => 15)

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{a1.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => a1.id.to_s, :id => student.id.to_s },
          { :comment => { :text_comment => "Why U no submit" } })

    Submission.count.should == 1
    @submission = Submission.first

    comment = @submission.submission_comments.first
    comment.should be_present
    comment.comment.should == "Why U no submit"
  end

  it "should allow clearing out the current grade with a blank grade" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    @assignment = @course.assignments.create!(:title => 'assignment1', :grading_type => 'points', :points_possible => 12)
    @assignment.grade_student(student, { :grade => '10' })
    Submission.count.should == 1
    @submission = Submission.first
    @submission.grade.should == '10'
    @submission.score.should == 10
    @submission.workflow_state.should == 'graded'

    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :submission => { :posted_grade => '' } })
    Submission.count.should == 1
    @submission = Submission.first
    @submission.grade.should be_nil
    @submission.score.should be_nil
  end

  it "should allow repeated changes to a submission to accumulate" do
    student = user(:active_all => true)
    course_with_teacher(:active_all => true)
    @course.enroll_student(student).accept!
    @assignment = @course.assignments.create!(:title => 'assignment1', :grading_type => 'points', :points_possible => 12)
    submit_homework(@assignment, student)

    # post a comment
    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :comment => { :text_comment => "This works" } })
    Submission.count.should == 1
    @submission = Submission.first

    # grade the submission
    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :submission => { :posted_grade => '10' } })
    Submission.count.should == 1
    @submission = Submission.first

    # post another comment
    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :comment => { :text_comment => "10/12 ain't bad" } })
    Submission.count.should == 1
    @submission = Submission.first

    json['grade'].should == '10'
    @submission.grade.should == '10'
    @submission.score.should == 10
    json['body'].should == 'test!'
    @submission.body.should == 'test!'
    json['submission_comments'].size.should == 2
    json['submission_comments'].first['comment'].should == "This works"
    json['submission_comments'].last['comment'].should == "10/12 ain't bad"
    @submission.user_id.should == student.id

    # post another grade
    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{student.id}.json",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => student.id.to_s },
          { :submission => { :posted_grade => '12' } })
    Submission.count.should == 1
    @submission = Submission.first

    json['grade'].should == '12'
    @submission.grade.should == '12'
    @submission.score.should == 12
    json['body'].should == 'test!'
    @submission.body.should == 'test!'
    json['submission_comments'].size.should == 2
    json['submission_comments'].first['comment'].should == "This works"
    json['submission_comments'].last['comment'].should == "10/12 ain't bad"
    @submission.user_id.should == student.id
  end

  it "should not allow accessing other sections when limited" do
    course_with_teacher(:active_all => true)
    @enrollment.update_attribute(:limit_priveleges_to_course_section, true)
    @teacher = @user
    s1 = submission_model(:course => @course)
    section2 = @course.course_sections.create(:name => "another section")
    s2 = submission_model(:course => @course, :username => 'otherstudent@example.com', :section => section2, :assignment => @assignment)
    @user = @teacher

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s })
    json.map { |u| u['user_id'] }.should == [s1.user_id]

    # try querying the other section directly
    json = api_call(:get,
          "/api/v1/sections/#{section2.id}/assignments/#{@assignment.id}/submissions",
          { :controller => 'submissions_api', :action => 'index',
            :format => 'json', :section_id => section2.id.to_s,
            :assignment_id => @assignment.id.to_s })
    json.size.should == 0

    raw_api_call(:get,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{s2.user_id}",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => s2.user_id.to_s })
    response.status.should == "404 Not Found"

    # try querying the other section directly
    raw_api_call(:get,
          "/api/v1/sections/#{section2.id}/assignments/#{@assignment.id}/submissions/#{s2.user_id}",
          { :controller => 'submissions_api', :action => 'show',
            :format => 'json', :section_id => section2.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => s2.user_id.to_s })
    response.status.should == "404 Not Found"

    json = api_call(:get,
          "/api/v1/courses/#{@course.id}/students/submissions",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :course_id => @course.id.to_s },
          { :student_ids => [s1.user_id, s2.user_id], :grouped => 1 })
    json.map { |u| u['user_id'] }.should == [s1.user_id]

    # try querying the other section directly
    json = api_call(:get,
          "/api/v1/sections/#{section2.id}/students/submissions",
          { :controller => 'submissions_api', :action => 'for_students',
            :format => 'json', :section_id => section2.id.to_s },
          { :student_ids => [s1.user_id, s2.user_id], :grouped => 1 })
    json.size.should == 0

    # grade the s1 submission, succeeds because the section is the same
    json = api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{s1.user_id}",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => s1.user_id.to_s },
          { :submission => { :posted_grade => '10' } })
    @submission = @assignment.submission_for_student(s1.user)
    @submission.should be_present
    @submission.grade.should == '10'

    # grading s2 will fail because the teacher can't manipulate this student's section
    raw_api_call(:put,
          "/api/v1/courses/#{@course.id}/assignments/#{@assignment.id}/submissions/#{s2.user_id}",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :course_id => @course.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => s2.user_id.to_s },
          { :submission => { :posted_grade => '10' } })
    response.status.should == "404 Not Found"

    # try querying the other section directly
    raw_api_call(:put,
          "/api/v1/sections/#{section2.id}/assignments/#{@assignment.id}/submissions/#{s2.user_id}",
          { :controller => 'submissions_api', :action => 'update',
            :format => 'json', :section_id => section2.id.to_s,
            :assignment_id => @assignment.id.to_s, :id => s2.user_id.to_s },
          { :submission => { :posted_grade => '10' } })
    response.status.should == "404 Not Found"
  end

end
