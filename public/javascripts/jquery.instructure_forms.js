/**
 * Copyright (C) 2011 Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

I18n.scoped('instructure', function(I18n) {
  
  // Intercepts the default form submission process.  Uses the form tag's
  // current action and method attributes to know where to submit to.
  // NOTE: because IE only allows form methods to be "POST" or "GET",
  // we can't set the form to "PUT" or "DELETE" as cleanly as we'd like.
  // I'm following the Rails convention, and adding a _method input
  // if one doesn't already exist, and then setting that input's value
  // to the method type.  formSubmit checks this value first, then
  // the checks form.data('method') and finally the form's method
  // attribute.
  // Options:
  //    validation options -- formSubmit calls validateForm before
  //      submitting, so you can pass in validation options to
  //      formSubmit and it will validate first.
  //    noSubmit: Option to call everything normally until the actual request,
  //      then just calls success with the processed data
  //    processData: formSubmit by default just calls $.fn.getFormData.
  //      if you need additional data in the form submission, add
  //      it here and return the new object.
  //    beforeSubmit: called right before the request is sent.  Useful
  //      for hiding forms, adding ajax loader icons, etc.
  //    success: called on success
  //    error: Called on error.  The response from the server will also
  //      be used to populate error boxes on form elements.  If the form
  //      no longer exists and no error method is provided, the default
  //      error method for Instructure is called... actually
  //      it will always be called when you're in development environment.
  //    fileUpload: Either a boolean or a function.  If it is true or
  //      returns true, then it's assumed this is a file upload request
  //      and we use the iframe trick to submit the form.
  $.fn.formSubmit = function(options) {
    this.submit(function(event) {
      var $form = $(this); //this is to handle if bind to a template element, then it gets cloned the original this would not be the same as the this inside of here.
      if($form.data('submitting')) { return; }
      $form.data('trigger_event', event);
      $form.hideErrors();
      var error = false;
      var result = $form.validateForm(options);
      if(!result) {
        return false;
      }
      // retrieve form data
      var formData = $form.getFormData(options);
      if(options.processData && $.isFunction(options.processData)) {
        var newData = null;
        try {
          newData = options.processData.call($form, formData);
        } catch(e) { error = e; }
        if(newData === false) {
          return false;
        } else if(newData) {
          formData = newData;
        }
      }
      var method = $form.data('method') || $form.find("input[name='_method']").val() || $form.attr('method'),
          formId = $form.attr('id'),
          action = $form.attr('action'),
          submitParam = null;
      if($.isFunction(options.beforeSubmit)) {
        submitParam = null;
        try {
          submitParam = options.beforeSubmit.call($form, formData);
        } catch(e) { error = e; }
        if(submitParam === false) {
          return false;
        }
      }
      
      if (options.disableWhileLoading) {
        var loadingPromise = $.Deferred(),
            oldHandlers = {};
        $form.disableWhileLoading(loadingPromise);
        $.each(['success', 'error'], function(i, successOrError){
          oldHandlers[successOrError] = options[successOrError];
          options[successOrError] = function() {
            loadingPromise[successOrError === 'success' ? 'resolve': 'reject']();
            if ($.isFunction(oldHandlers[successOrError])) {
              return oldHandlers[successOrError].apply(this, arguments);
            }
          };
        });
      }
      
      var doUploadFile = options.fileUpload;
      if($.isFunction(options.fileUpload)) {
        try {
          doUploadFile = options.fileUpload.call($form, formData);
        } catch(e) { error = e; }
      }
      if(doUploadFile && options.fileUploadOptions) {
        $.extend(options, options.fileUploadOptions);
      }
      if($form.attr('action')) {
        action = $form.attr('action');
      }
      if(error && !options.preventDegradeToFormSubmit) {
        if (loadingPromise) loadingPromise.reject();
        if(INST && INST.environment == 'development') {
          $.flashError('formSubmit error, trying to gracefully degrade. See console for details');
        }
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      if(options.noSubmit) {
        if($.isFunction(options.success)) {
          loadingPromise.resolve();
          options.success.call($form, formData, submitParam);
        }
      } else if(doUploadFile && options.preparedFileUpload && options.context_code) {
        $.ajaxJSONPreparedFiles.call(this, {
          handle_files: (options.upload_only ? options.success : options.handle_files),
          single_file: options.singleFile,
          context_code: $.isFunction(options.context_code) ? (options.context_code.call($form)) : options.context_code,
          asset_string: options.asset_string,
          intent: options.intent,
          folder_id: $.isFunction(options.folder_id) ? (options.folder_id.call($form)) : options.folder_id,
          file_elements: $form.find("input[type='file']"),
          url: (options.upload_only ? null : action),
          uploadDataUrl: options.uploadDataUrl,
          formData: options.postFormData ? formData : null,
          success: options.success,
          error: options.error
        });
      } else if(doUploadFile && $.handlesHTML5Files && $form.hasClass('handlingHTML5Files')) {
        var args = $.extend({}, formData);
        $form.find("input[type='file']").each(function() {
          var $input = $(this),
              file_list = $input.data('file_list');
          if(file_list && (file_list instanceof FileList)) {
            args[$input.attr('name')] = file_list;
          }
        });
        $.toMultipartForm(args, function(params) {
          $.sendFormAsBinary({
            url: action,
            body: params.body,
            content_type: params.content_type,
            form_data: params.form_data,
            method: method,
            success: function(data) {
              if(options.success && $.isFunction(options.success)) {
                options.success.call($form, data, submitParam);
              }
            },
            error: function(data, request) {
              // error function
              var $formObj = $form,
                  needValidForm = true;
              
              if(options.error && $.isFunction(options.error)) {
                data = data || {};
                var $obj = options.error.call($form, data.errors || data, submitParam);
                if($obj) {
                  $formObj = $obj;
                }
                needValidForm = false;
              } else {
                needValidForm = true;
              }
              if($formObj.parents("html").get(0) == $("html").get(0) && options.formErrors !== false) {
                $formObj.formErrors(data);
              } else if(needValidForm) {
                $.ajaxJSON.unhandledXHRs.push(request);
              }
            }
          });
        });
      } else if(doUploadFile) {
        var id            = $.uniqueId(formId + "_"),
            $frame        = $("<div style='display: none;' id='box_" + id + "'><form id='form_" + id + "'></form><iframe id='frame_" + id + "' name='frame_" + id + "' src='about:blank' onload='$(\"#frame_" + id + "\").triggerHandler(\"form_response_loaded\");'></iframe>")
                                .appendTo("body").find("#frame_" + id),
            $frameForm    = $(this),
            formMethod    = method,
            priorTarget   = $frameForm.attr('target'),
            priorEnctype  = $frameForm.attr('ENCTYPE'),
            request       = new $.fakeXHR(0, ""),
            $originalForm = $form;

        $frameForm.attr({
          'method' : method,
          'action' : action,
          'ENCTYPE' : 'multipart/form-data',
          'encoding' : 'multipart/form-data',
          'target' :"frame_" + id
        });
        if(options.onlyGivenParameters) {
          $frameForm.find("input[name='_method']").remove();
          $frameForm.find("input[name='authenticity_token']").remove();
        }

        $.ajaxJSON.storeRequest(request, action, method, formData);
        
        $frame.bind('form_response_loaded', function() {
          var $form = $originalForm,
              i = $frame[0],
              doc,
              exception;
          if (i.contentDocument) {
            doc = i.contentDocument;
          } else if (i.contentWindow) {
            doc = i.contentWindow.document;
          } else {
            doc = window.frames[id].document;
          }
          var text = "";
          var href = null;
          var exception = null;
          try {
            if(doc.location.href == "about:blank") {
              return;
            }
            text = $(doc).text();
            var data = JSON.parse(text);
            if(options.success && $.isFunction(options.success) && data && !data.errors) {
              options.success.call($form, data, submitParam);
            }
          } catch(e) {
            data = {};
            exception = e;
          }
          if(exception || data.errors) {
            var $formObj = $form,
                needValidForm = true;
            
            request.responseText = text;
            if(options.error && $.isFunction(options.error)) {
              var $obj = options.error.call($form, (data.errors || text), submitParam);
              if($obj) {
                $formObj = $obj;
              }
              needValidForm = false;
            } else if($.fn.formSubmit.defaultAjaxErrorObject && $.isFunction($.fn.formSubmit.defaultAjaxErrorFunction)) {
              needValidForm = true;
            }
            if($formObj.parents("html").get(0) == $("html").get(0) && options.formErrors !== false) {
              $formObj.formErrors(data.errrors || data);
            } else if(needValidForm) {
              $.ajaxJSON.unhandledXHRs.push(request);
            }
            $.fn.defaultAjaxError.func.call($.fn.defaultAjaxError.object, null, request, "0", exception);
          }
          setTimeout(function() {
            $form.attr({
              'ENCTYPE': priorEnctype,
              'encoding': priorEnctype,
              'target':  priorTarget
            });
            $("#box_" + id).remove();
          }, 5000);
        });
        $frameForm.data('submitting', true).submit().data('submitting', false);
      } else {
        $.ajaxJSON(action, method, formData, function(data) {
          // success function
          if($.isFunction(options.success)) {
            options.success.call($form, data, submitParam);
          }
        }, function(data, request, status, error) {
          // error function
          data = data || {};
          var $formObj = $form,
              needValidForm = true;
          if($.isFunction(options.error)) {
            var $obj = options.error.call($form, data.errors || data, submitParam);
            if($obj) {
              $formObj = $obj;
            }
            needValidForm = false;
          } else {
            needValidForm = true;
          }
          if($formObj.parents("html").get(0) == $("html").get(0) && options.formErrors !== false) {
            $formObj.formErrors(data);
          } else if(needValidForm) {
            $.ajaxJSON.unhandledXHRs.push(request);
          }
        });
      }
    });
    return this;
  };
  
  $.handlesHTML5Files = !!(window.File && window.FileReader && window.FileList && XMLHttpRequest);
  if($.handlesHTML5Files) {
    $("input[type='file']").live('change', function(event) {
      var file_list = this.files;
      if(file_list) {
        $(this).data('file_list', file_list);
        $(this).parents("form").addClass('handlingHTML5Files');
      }
    });
  }
  $.ajaxFileUpload = function(options) {
    if(!options.data.authenticity_token) {
      options.data.authenticity_token = $("#ajax_authenticity_token").text();
    }
    $.toMultipartForm(options.data, function(params) {
      $.sendFormAsBinary({
        url: options.url,
        body: params.body,
        content_type: params.content_type,
        form_data: params.form_data,
        method: options.method,
        success: function(data) {
          if(options.success && $.isFunction(options.success)) {
            options.success.call(this, data);
          }
        },
        progress: function(data) {
          if(options.progress && $.isFunction(options.progress)) {
            options.progress.call(this, data);
          }
        },
        error: function(data, request) {
          // error function
          if(options.error && $.isFunction(options.error)) {
            data = data || {};
            var $obj = options.error.call(this, data.errors || data);
          } else {
            $.ajaxJSON.unhandledXHRs.push(request);
          }
        }
      }, options.binary === false);
    });
  };

  $.httpSuccess = function(r) {
    try {
      return !r.status && location.protocol == "file:" ||
        ( r.status >= 200 && r.status < 300 ) || r.status == 304 ||
        jQuery.browser.safari && r.status == undefined;
    } catch(e){}

    return false;
  };

  $.sendFormAsBinary = function(options, not_binary) {
    var body = options.body;
    var url = options.url;
    var method = options.method;
    var xhr = new XMLHttpRequest();
    if(xhr.upload) {
      xhr.upload.addEventListener('progress', function(event) {
        if(options.progress && $.isFunction(options.progress)) {
          options.progress.call(this, event); 
        }
      }, false);
      xhr.upload.addEventListener('error', function(event) {
        if(options.error && $.isFunction(options.error)) {
          options.error.call(this, "uploading error", xhr, event);
        }
      }, false);
      xhr.upload.addEventListener('abort', function(event) {
        if(options.error && $.isFunction(options.error)) {
          options.error.call(this, "aborted by the user", xhr, event);
        }
      }, false);
      xhr.onreadystatechange = function(event) {
        if(xhr.readyState == 4) {
          var json = null;
          try {
            json = JSON.parse(xhr.responseText);
          } catch(e) { }
          if($.httpSuccess(xhr)) {
            if(json && !json.errors) {
              if(options.success && $.isFunction(options.success)) {
                options.success.call(this, json, xhr, event);
              }
            } else {
              if(options.error && $.isFunction(options.error)) {
                options.error.call(this, json || xhr.responseText, xhr, event);
              }
            }
          } else {
            if(options.error && $.isFunction(options.error)) {
              options.error.call(this, json || xhr.responseText, xhr, event);
            }
          }
        }
      };
    }
    xhr.open(method, url);
    xhr.setRequestHeader('Accept', 'application/json, text/javascript, */*');
    xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
    if(options.form_data) {
      xhr.send(options.form_data);
    } else {
      xhr.overrideMimeType(options.content_type || "multipart/form-data");
      
      xhr.setRequestHeader('Content-Type', options.content_type || "multipart/form-data");
      xhr.setRequestHeader('Content-Length', body.length);
      if(not_binary) {
        xhr.send(body);
      } else {
        if(!xhr.sendAsBinary) {
          console.log('xhr.sendAsBinary not supported');
        } else {
          xhr.sendAsBinary(body);
        }
      }
    }
  };
  
  $.fileData = function(file_object) {
    return {
      name: file_object.name || file_object.fileName,
      size: file_object.size || file_object.fileSize,
      type: file_object.type,
      forced_type: file_object.type || "application/octet-stream"
    };
  };
    
  $.toMultipartForm = function(params, callback) {
    var boundary = "-----AaB03x" + $.uniqueId(),
        result = {content_type: "multipart/form-data; boundary=" + boundary},
        body = "--" + boundary + "\r\n",
        paramsList = [],
        hasFakeFile = false;
    
    for(var idx in params) {
      paramsList.push([idx, params[idx]]);
      if (params[idx] && params[idx].fake_file) {
        hasFakeFile = true;
      }
    }
    if(window.FormData && !hasFakeFile) {
      var fd = new FormData();
      for(var idx in params) {
        var param = params[idx];
        if(window.FileList && (param instanceof FileList)) {
          param = param[0];
        }
        if (param instanceof Array) {
          for (var i = 0; i < param.length; i++) {
            fd.append(idx, param[i]);
          }
        } else {
          fd.append(idx, param);
        }
      }
      result.form_data = fd;
      callback(result);
      return;
    }
    function sanitizeQuotedString(text) {
      return text.replace(/\"/g, "");
    }
    function finished() {
      result.body = body.substring(0, body.length - 2) + '--';
      callback(result);
    };
    function nextParam() {
      if(paramsList.length === 0) {
        finished();
        return;
      }
      var param = paramsList.shift(),
          name = param[0],
          value = param[1];
      
      if(window.FileList && (value instanceof FileList)) {
        value = value[0];
      }
      if(window.FileList && (value instanceof FileList)) {
        var innerBoundary = "-----BbC04y" + $.uniqueId(),
            fileList = [];
        body += "Content-Disposition: form-data; name=\"" + sanitizeQuotedString(name) + "\r\n" +
                "Content-Type: multipart/mixed; boundary=" + innerBoundary + "\r\n\r\n";
        for(var jdx in value) {
          fileList.push(value);
        }
        function finishedFiles() {
          body += "--" + innerBoundary + "--\r\n" +
                  "--" + boundary + "\r\n";
          nextParam();
        }
        function nextFile() {
          if(fileList.length === 0) {
            finishedFiles();
            return;
          }
          var file = fileList.shift(),
              fileData = $.fileData(file),
              reader = new FileReader();
          
          reader.onloadend = function() {
            body += "--" + innerBoundary + "\r\n" +
                    "Content-Disposition: file; filename=\"" + sanitizeQuotedString(fileData.name) + "\"\r\n" +
                    "Content-Type: " + fileData.forced_type + "\r\n" +
                    "Content-Transfer-Encoding: binary\r\n" +
                    "\r\n" +
                    reader.result;
            nextFile();
          };
          reader.readAsBinaryString(file);
        }
        nextFile();
      } else if(window.File && (value instanceof File)) {
        var fileData = $.fileData(value),
            reader = new FileReader();
        reader.onloadend = function() {
          body += "Content-Disposition: file; name=\"" + sanitizeQuotedString(name) + "\"; filename=\"" + fileData.name + "\"\r\n" +
                  "Content-Type: " + fileData.forced_type + "\r\n" +
                  "Content-Transfer-Encoding: binary\r\n" + 
                  "\r\n" + 
                  reader.result + 
                  "\r\n--" + boundary + "\r\n";
          nextParam();
        };
        reader.readAsBinaryString(value);
      } else if(value && value.fake_file) {
        body += "Content-Disposition: file; name=\"" + sanitizeQuotedString(name) + "\"; filename=\"" + value.name + "\"\r\n" + 
                "Content-Type: " + value.content_type + "\r\n" + 
                "Content-Transfer-Encoding: binary\r\n" + 
                "\r\n" + 
                value.content + 
                "\r\n--" + boundary + "\r\n";
        nextParam();
      } else {
        body += "Content-Disposition: form-data; name=\"" + sanitizeQuotedString(name) + "\"\r\n" + 
                "\r\n" + 
                (value || "").toString() + "\r\n" + 
                "--" + boundary + "\r\n";
        nextParam();
      }
    };
    nextParam();
  };
  
  // Used to make a fake XHR request, useful if there's errors on an
  // asynchronous request generated using the iframe trick.
  $.fakeXHR = function(status_code, text) {
    this.status = status_code;
    this.responseText = text;
  };
  
  // Defines a default error for all ajax requests.  Will always be called
  // in the development environment, and as a last-ditch error catching
  // otherwise.  See "ajax_errors.js"
  $.fn.defaultAjaxError = function(func) {
    $.fn.defaultAjaxError.object = this;
    $.fn.defaultAjaxError.func = function(event, request, settings, error) {
      var inProduction = (INST.environment == "production");
      var unhandled = ($.inArray(request, $.ajaxJSON.unhandledXHRs) != -1);
      var ignore = ($.inArray(request, $.ajaxJSON.ignoredXHRs) != -1);
      if((!inProduction || unhandled) && !ignore) {
        $.ajaxJSON.unhandledXHRs = $.grep($.ajaxJSON.unhandledXHRs, function(xhr, i) {
          return xhr != request;
        });
        var debugOnly = false;
        if(!unhandled) {
          debugOnly = true;
        }
        func.call(this, event, request, settings, error, debugOnly);
      }
    };
    this.ajaxError($.fn.defaultAjaxError.func);
  };
  
  // Fills the selected form object with the collected data values.
  // Handles select boxes, check boxes and radios as well.
  //  object_name: Name of the object form form elements.  So if
  //    I provide the data {good: true, bad: false} and
  //    options.object_name == "assignment", then it will fill
  //    form elements "good" and "assignment[good]" with true
  //    and "bad" and "assignment[bad]" with false.
  //  call_change: Specifies whether to trigger the onchange event
  //    for form elements that are set.
  $.fn.fillFormData = function(data, opts) {
    if(this.length) {
      data = data || [];
      var options = $.extend({}, $.fn.fillFormData.defaults, opts);

      if(options.object_name) {
        data = $._addObjectName(data, options.object_name, true);
      }
      this.find(":input").each(function() {
        var $obj = $(this);
        var name = $obj.attr('name');
        var inputType = $obj.attr('type');
        if(name in data) {
          if(name) {
            if(inputType == "hidden" && $obj.next("input:checkbox").attr('name') == name) {
              // do nothing
            } else if(inputType != "checkbox" && inputType != "radio") {
              var val = data[name];
              if(typeof(val) == 'undefined' || val === null) { val = ""; }
              $obj.val(val.toString());
            } else {
              if($obj.val() == data[name]) {
                $obj.attr('checked', true);
              } else {
                $obj.attr('checked', false);
              }
            }
            if($obj && $obj.change && options.call_change) {
              $obj.change();
            }
          }
        }
      });
    }
    return this;
  };
  $.fn.fillFormData.defaults = {object_name: null, call_change: true};
  // Pulls out the selected and entered values on a given form.
  //    object_name: see fillFormData above.  If object_name == "assignment"
  //      and the form has an element named "assignment[good]" then
  //      the result will include both "assignment[good]" and "good"
  //    values: specify the set of values to retrieve (if they exist)
  //      by default retrieves all it can find.
  $.fn.getFormData = function(options) {
    var options = $.extend({}, $.fn.getFormData.defaults, options),
        result = {},
        $form = this;
    $form.find(":input").not(":button").each(function() {
      var $input = $(this),
          inputType = $(this).attr('type');
      if((inputType == "radio" || inputType == 'checkbox') && !$input.attr('checked')) { return; }
      var val = $input.val();
      if($input.hasClass('suggestion_title') && $input.attr('title') == val) {
        val = "";
      } else if($input.hasClass('datetime_field_enabled') && $input.parent().children(".datetime_suggest").text()) {
        if($input.parent().children('.datetime_suggest').hasClass('invalid_datetime')) {
          val = $input.parent().children('.datetime_suggest').text();
        } else {
          val = $input.parent().children('.datetime_suggest').text();
        }
      }
      try {
        if($input.data('rich_text')) {
          val = $input.editorBox('get_code', false);
        }
      } catch(e) {}
      var attr = $input.prop('name') || '';
      var multiValue = attr.match(/\[\]$/)
      if(inputType == 'hidden' && !multiValue) {
        if($form.find("[name='" + attr + "']").filter("textarea,:radio:checked,:checkbox:checked,:text,:password,select,:hidden")[0] != $input[0]) {
          return;
        }
      }
      if(attr && attr !== "" && (inputType == "checkbox" || typeof(result[attr]) == "undefined" || multiValue)) {
        if(!options.values || $.inArray(attr, options.values) != -1) {
          if(multiValue) {
            result[attr] = result[attr] || [];
            result[attr].push(val);
          } else {
            result[attr] = val;
          }
        }
      }
      var lastAttr = attr;
    });
    if(options.object_name) {
      result = $._stripObjectName(result, options.object_name, true);
    }
    return result;
  };
  $.fn.getFormData.defaults = {object_name: null};
  
  
  // Used internally to prepend object_name to data key names
  // Supports nested names, e.g.
  //      assignment[id] => discussion_topic[assignment][id]
  $._addObjectName = function(data, object_name, include_original) {
    if(!data) { return data; }
    var new_result = {};
    if(data instanceof Array) {
      new_result = [];
    }
    var original_name,
        new_name,
        first_bracket;
        
    for(var i in data) {
      if(data instanceof Array) {
        original_name = data[i];
      } else {
        original_name = i;
      }

      first_bracket = original_name.indexOf('[');
      if (first_bracket >= 0) {
        new_name = object_name + "[" + original_name.substring(0, first_bracket) + "]" + original_name.substring(first_bracket);
      } else {
        new_name = object_name + "[" + original_name + "]";
      }
      if(typeof(original_name) == "string" && original_name.indexOf("=") === 0) {
        new_name = original_name.substring(1);
        original_name = new_name;
      }

      if(data instanceof Array) {
        new_result.push(new_name);
        if(include_original) {
          new_result.push(original_name);
        }
      } else {
        new_result[new_name] = data[i];
        if(include_original) {
          new_result[original_name] = data[i];
        }
      }
    }
    return new_result;
  };
  // Used internally to strip object_name from data key names
  // Supports nested names, e.g.
  //      discussion_topic[assignment][id] => assignment[id]
  $._stripObjectName = function(data, object_name, include_original) {
    var new_result = {};
    var short_name;
    if(data instanceof Array) {
      new_result = [];
    }
    for(var i in data) {
      var original_name, found;
      if(data instanceof Array) {
        original_name = data[i];
      } else {
        original_name = i;
      }

      if(found = (original_name.indexOf(object_name + "[") === 0)) {
        short_name = original_name.replace(object_name + "[", "");
        closing = short_name.indexOf("]");
        short_name = short_name.substring(0, closing) + short_name.substring(closing + 1);
        if(data instanceof Array) {
          new_result.push(short_name);
        } else {
          new_result[short_name] = data[i];
        }
      }

      if (!found || include_original) {
        if(data instanceof Array) {
          new_result.push(data[i]);
        } else {
          new_result[i] = data[i];
        }
      }
    }
    return new_result;
  };
  
  // Validated the selected form.  Pops up little error messages
  // next to form elements that have errors.
  //  object_name: specify to make error checking easier.  If object_name == "assignment"
  //    and required included "good", then "assignment[good]" is required. Only
  //    useful if all validations use the given object_name
  //  required: a list of strings, elements that are required
  //  dates: list of strings, elements that must be blank or a valid date
  //  times: list of strings, elements that must be blank or a valid time
  //  numbers: list of strings, elements that must be blank or a valid number
  //  property_validations: hash, where key names are form element names
  //    and key values are functions to call on the given data.  The function
  //    should return true if valid, false otherwise.
  $.fn.validateForm = function(options) {
    if (this.length === 0) {
      return false;
    }
    var options = $.extend({}, $.fn.validateForm.defaults, options),
        $form = this,
        errors = {},
        data = options.data || $form.getFormData(options);

    if (options.object_name) {
      options.required = $._addObjectName(options.required, options.object_name);
      options.date_fields = $._addObjectName(options.date_fields, options.object_name);
      options.dates = $._addObjectName(options.dates, options.object_name);
      options.times = $._addObjectName(options.times, options.object_name);
      options.numbers = $._addObjectName(options.numbers, options.object_name);
      options.property_validations = $._addObjectName(options.property_validations, options.object_name);
    }
    if (options.required) {
      $.each(options.required, function(i, name) {
        if (!data[name]) {
          if (!errors[name]) { 
            errors[name] = []; 
          }
          errors[name].push(I18n.t('errors.field_is_required', "This field is required"));
        }
      });
    }
    if(options.date_fields) {
      $.each(options.date_fields, function(i, name) {
        var $item = $form.find("input[name='" + name + "']").filter(".datetime_field_enabled");
        if($item.length && $item.parent().children(".datetime_suggest").hasClass('invalid_datetime')) {
          if (!errors[name]) { 
            errors[name] = []; 
          }
          errors[name].push(I18n.t('errors.invalid_datetime', "Invalid date/time value"));
        }
      });
    }
    if (options.numbers) {
      $.each(options.numbers, function(i, name){
        var val = parseFloat(data[name]);
        if(isNaN(val)) {
          if(!errors[name]) { 
            errors[name] = []; 
          }
          errors[name].push(I18n.t('errors.invalid_number', "This should be a number."));
        }
      });
    }
    if(options.property_validations) {
      $.each(options.property_validations, function(name, validation) {
        if($.isFunction(validation)) {
          var result = validation.call($form, data[name], data);
          if(result) {
            if(typeof(result) != "string") {
              result = I18n.t('errors.invalid_entry_for_field', "Invalid entry: %{field}", {field: name});
            }
            if(!errors[name]) { errors[name] = []; }
            errors[name].push(result);
          }
        }
      });
    }
    var hasErrors = false;
    for(var err in errors) {
      hasErrors = true;
      break;
    }
    if(hasErrors) {
      $form.formErrors(errors);
      $.trackEvent("Form Errors", this.attr('id') || this.attr('class') || document.title, JSON.stringify(errors));
      return false;
    }
    return true;
  };
  $.fn.validateForm.defaults = {object_name: null, required: null, dates: null, times: null};
  // Takes in an errors object and creates little pop-up message boxes over
  // each errored form field displaying the error text.  Still needs some
  // css lovin'.
  $.fn.formErrors = function(data_errors) {
    if(this.length === 0) {
      return;
    }
    var $form = this;
    var errors = {};
    var elementErrors = [];
    if(data_errors && data_errors['errors']) {
      data_errors = data_errors['errors'];
    }
    if(typeof(data_errors) == 'string') { 
      data_errors = {base: data_errors}; 
    }
    $.each(data_errors, function(i, val) {
      if(typeof(val) == "string") {
        var newval = [];
        newval.push(val);
        val = newval;
      } else if(typeof(i) == "number" && val.length == 2 && (val[0] instanceof jQuery) && typeof(val[1]) == "string") {
        elementErrors.push(val);
        return;
      } else if(typeof(i) == "number" && val.length == 2 && typeof(val[1]) == "string") {
        newval = [];
        newval.push(val[1]);
        i = val[0];
        val = newval;
      } else {
        try {
          newval = [];
          for(var idx in val) {
            if(typeof(val[idx]) == "object" && val[idx].message) {
              newval.push(val[idx].message.toString());
            } else {
              newval.push(val[idx].toString());
            }
          }
          val = newval;
        } catch(e) {
          val = val.toString();
        }
      }
      if($form.find(":input[name='" + i + "'],:input[name*='[" + i + "]']").length > 0) {
        $.each(val, function(idx, msg) {
          if(!errors[i]) {
            errors[i] = msg;
          } else {
            errors[i] += "<br/>" + msg;
          }
        });
      } else {
        $.each(val, function(idx, msg) {
          if(!errors.general) {
            errors.general = msg;
          } else {
            errors.general += "<br/>" + msg;
          }
        });
      }
    });
    var hasErrors = false;
    var highestTop = 0;
    var currentTop = $(document).scrollTop();
    $.each(errors, function(name, msg) {
      var $obj = $form.find(":input[name='" + name + "'],:input[name*='[" + name + "]']").filter(":first");
      if(!$obj || $obj.length === 0 || name == "general") {
        $obj = $form;
      }
      if($obj[0].tagName == 'TEXTAREA' && $obj.next('.mceEditor').length) {
        $obj = $obj.next().find(".mceIframeContainer");
      }
      hasErrors = true;
      var offset = $obj.errorBox(msg).offset();
      if(offset.top > highestTop) {
        highestTop = offset.top;
      }
    });
    for(var idx in elementErrors) {
      var $obj = elementErrors[idx][0];
      var msg = elementErrors[idx][1];
      hasErrors = true;
      var offset = $obj.errorBox(msg).offset();
      if(offset.top > highestTop) {
        highestTop = offset.top;
      }
    }
    if(hasErrors) {
      $('html,body').scrollTo({top: highestTop, left:0});
    }
    return this;
  };

  // Pops up a small box containing the given message.  The box is connected to the given form element, and will
  // go away when the element is selected.
  $.fn.errorBox = function(message, scroll) {
    if(this.length) {
      var $obj = this,
          $oldBox = $obj.data('associated_error_box');
      if($oldBox) {
        $oldBox.remove();
      }
      var $template = $("#error_box_template");
      if(!$template.length) {
        $template = $("<div id='error_box_template' class='error_box errorBox' style=''>" + 
                          "<div class='error_text' style=''></div>" +
                          "<img src='/images/error_bottom.png' class='error_bottom'/>" + 
                        "</div>").appendTo("body");
      }
      var $box = $template.clone(true).attr('id', '').css('zIndex', $obj.zIndex() + 1).appendTo("body");
      $box.find(".error_text").html(message);
      var offset = $obj.offset();
      var height = $box.outerHeight();
      var objLeftIndent = Math.round($obj.outerWidth() / 5);
      if($obj[0].tagName == "FORM") {
        objLeftIndent = Math.min(objLeftIndent, 50);
      }
      $box.hide().css({
        top: offset.top - height + 2,
        left: offset.left + objLeftIndent
      }).fadeIn('fast');
      
      $obj.data({
        associated_error_box :$box,
        associated_error_object: $obj
      }).focus(function() {
        $box.fadeOut('slow', function() {
          $box.remove();
        });
      });
        
      $box.click(function() {
        $(this).fadeOut('fast', function() {
          $(this).remove();
        });
      });
      $.fn.errorBox.errorBoxes.push($obj);
      if(!$.fn.errorBox.isBeingAdjusted) {
        $.moveErrorBoxes();
      }
      if(scroll) {
        $("html,body").scrollTo($box);
      }
      return $box;
    }
  };
  $.fn.errorBox.errorBoxes = [];
  $.moveErrorBoxes = function() {
    if(!$.fn.errorBox.isBeingAdjusted) {
      $.fn.errorBox.isBeingAdjusted = true;
      setInterval($.moveErrorBoxes, 500);
    }
    var list = [];
    var prevList = $.fn.errorBox.errorBoxes;
    $(".error_box:visible").each(function() {
      var $box = $(this);
      if(!$box.data('associated_error_object') || $box.data('associated_error_object').filter(":visible").length === 0) {
        $box.hide();
      }
    });
    for(var idx in prevList) {
      var $obj = prevList[idx].filter(":visible:first");
      if($obj.data('associated_error_box')) {
        list.push($obj);
        var $box = $obj.data('associated_error_box');
        if($obj.filter(":visible").length === 0) {
          $box.hide();
        } else {
          var offset = $obj.offset();
          var height = $box.outerHeight();
          var objLeftIndent = Math.round($obj.outerWidth() / 5);
          if($obj[0].tagName == "FORM") {
            objLeftIndent = Math.min(objLeftIndent, 50);
          }
          $box.css({
            top: offset.top - height + 2,
            left: offset.left + objLeftIndent
          }).show();
        }
      }
    }
    $.fn.errorBox.errorBoxes = list;
  };
  // Hides all error boxes for the given form element and its input elements.
  $.fn.hideErrors = function(options) {
    if(this.length) {
      var $oldBox = this.data('associated_error_box');
      if($oldBox) {
        $oldBox.remove();
        this.data('associated_error_box', null);
      }
      this.find(":input").each(function() {
        var $obj = $(this),
            $oldBox = $obj.data('associated_error_box');
        if($oldBox) {
          $oldBox.remove();
          $obj.data('associated_error_box', null);
        }
      });
    }
    return this;
  };
  
  // Shows a gray-colored text suggestion for the form object when it is
  // blank, i.e. a date field would show DD-MM-YYYY until the user clicks on it.
  // I may phase this out or rewrite it, I'm undecided.  It's not
  // being used very much yet.
  $.fn.formSuggestion = function() {
    return this.each(function() {
      var $this = $(this);
      $this.focus(function(event) {
        var $this = $(this),
            title = $this.attr('title');
        $this.addClass('suggestionFocus');
        if(!title || title === "") { return; }
        if($this.val() == title) {
          $this.select();
        }
        $this.removeClass("form_text_hint");
      }).blur(function(event) {
        var $this = $(this),
            title = $this.attr('title');
        $this.removeClass('suggestionFocus');
        if(!title || title === "") { return; }
        if($this.val() === "") {
          $this.val(title);
        }
        if($this.val() == title) {
          $this.addClass("form_text_hint");
        }
      })
      // Workaround a strage bug where the input would be selected then immediately unselected 
      // every other time you clicked on the input with its defaultValue being shown
      .mouseup(false)
      .change(function(event) {
        var $this = $(this),
            title;
        if ( !$this.hasClass('suggestionFocus') && ( title = $(this).attr('title') ) ) {
          $this.removeClass('suggestionFocus');
          if ($this.val() === "") {
            $this.val(title);
          }
          $this.toggleClass("form_text_hint", $this.val() == title);
        }
      }).addClass('suggestion_title');
      
      var title = $this.attr('title'),
          val   = $this.val();
      if ( title && ( val === "" || val == title) ) {
        $this.addClass("form_text_hint").val(title);
      }
    });
  };
  $.fn.formSuggestion.suggestions = [];
  
});
