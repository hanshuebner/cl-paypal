(in-package :cl-paypal)

(define-condition paypal-error (error)
  ())

(define-condition request-error (paypal-error)
  ())

(define-condition http-request-error (paypal-error)
  ((http-status :initarg :http-status)
   (response-string :initarg :response-string)))

(define-condition response-error (paypal-error)
  ((response :accessor response-error-response :initarg :response)
   (invalid-parameter :initarg :invalid-parameter))
  (:report (lambda (condition stream)
             (let ((*print-length* 20))
               (format stream "Response: ~S" (response-error-response condition))))))

(define-condition transaction-already-confirmed-error (response-error)
  ())

(defun decode-response (response)
  "Decode a paypal response string, which is URL encoded and follow
  list encoding rules.  Returns the parameters as a plist."
  (let ((hash (make-hash-table :test 'equal)))
    (dolist (entry (cl-ppcre:split "&" response))
      (destructuring-bind (parameter-string value) (cl-ppcre:split "=" entry :limit 2)
	(setf parameter-string
	      (cl-ppcre:regex-replace "PAYMENTREQUEST_0_" parameter-string ""))
	(setf parameter-string
	      (cl-ppcre:regex-replace "PAYMENTINFO_0_" parameter-string ""))
        (multiple-value-bind (match registers) (cl-ppcre:scan-to-strings "^L_(.*?)([0-9]+)$" parameter-string)
          (if match
              (let* ((parameter (intern (aref registers 0) :keyword))
                     (index (parse-integer (aref registers 1)))
                     (previous-value (gethash parameter hash)))
		(format t "parameter ~A string ~A index ~A prev-value ~A value ~A~%"
			parameter parameter-string index previous-value (hunchentoot:url-decode value :utf-8))
		(if (= index 0)
		    (progn
		      (setf (gethash parameter hash)
			    (hunchentoot:url-decode value :utf-8)))
		    (progn
		      (if (listp previous-value)
			  (progn
			    (unless (= (length previous-value) index)
			      (error 'response-error :invalid-parameter parameter-string :response response))
			    (setf (gethash parameter hash)
				  (append previous-value (list (hunchentoot:url-decode value :utf-8)))))
			  (setf (gethash parameter hash)
				(list previous-value (hunchentoot:url-decode value :utf-8)))))))
	      (progn
		(setf (gethash (intern parameter-string :keyword) hash)
		      (hunchentoot:url-decode value :utf-8)))))))
    (loop for key being the hash-keys of hash
         collect key
         collect (gethash key hash))))

(defun request (method &rest args &key &allow-other-keys)
  "Perform a request to the Paypal NVP API.  METHOD is the method to
  use, additional keyword arguments are passed as parameters to the
  API.  Returns "
  (multiple-value-bind (response-string http-status)
      (drakma:http-request *paypal-api-url*
                           :method :post
                           :parameters (append (list (cons "METHOD" method)
                                                     (cons "VERSION" "63.0")
                                                     (cons "USER" *paypal-user*)
                                                     (cons "PWD" *paypal-password*)
                                                     (cons "SIGNATURE" *paypal-signature*)
						     )
                                               (loop for (param value) on args by #'cddr
                                                  collect (cons (symbol-name param)
                                                                (if (stringp value)
                                                                    value
                                                                    (princ-to-string value))))))
    (unless (= 200 http-status)
      (error 'http-request-error :http-status http-status :response-string response-string))
    (let ((response (decode-response response-string)))
      (unless (string-equal "Success" (getf response :ack))
        (if (equal "10415" (car (getf response :errorcode)))
          (error 'transaction-already-confirmed-error :response response)
          (error 'response-error :response response)))
      response)))

;; TODO should record time and gc this table regularly
;; also limit number of unfinished txns per ip to avoid
;; attackers filling up our heap.
(defvar *active-transactions* (make-hash-table :test #'equalp))
(defvar *transaction-ips* nil)

(defun all-transactions ()
  (let ((result (list)))
    (maphash #'(lambda (key val) (declare (ignore val))
		       (push key result)) *active-transactions*)
    (nreverse result)))

(defun remove-all-transactions ()
  (mapc #'unregister-transaction (all-transactions)))

(defun register-transaction (token amount currencycode ip)

  (when (gethash token *active-transactions*)
    (error "Attempt to register already existing transaction with token ~S." token))
     ;; Garbage collection

  (if (>= (hash-table-count *active-transactions*) *paypal-max-active-transactions*)
      (with-hash-table-iterator (next-entry *active-transactions*)
        (loop (multiple-value-bind (more key value) (next-entry)
             (unless more (return nil))
             (when (> (- (get-universal-time) (fourth value))
                    (* 60 *paypal-max-token-live-period*))
                 (unregister-transaction key))))))

  (if (>= (count ip *transaction-ips* :test #'equal) *paypal-max-transaction-per-ip*)
      (error "Attempt to make more than ~A transactions per IP" *paypal-max-transaction-per-ip*)
      (push ip *transaction-ips*))
  
  (setf (gethash token *active-transactions*) 
        (list amount currencycode ip (get-universal-time))))

(defun unregister-transaction (token)
  (setf *transaction-ips*
   (remove (third (gethash token *active-transactions*)) 
           *transaction-ips* :test #'equal :count 1))
  (remhash token *active-transactions*))

(defun find-transaction (token &optional (errorp t))
  (let ((result (gethash token *active-transactions*)))
    (when (and (not result) errorp)
      (error "Couldn't find transaction for token ~S" token))
    result))

(defun make-express-checkout-url (amount 
                                  ip
				  &rest args
				  &key
				  (return-url *paypal-return-url*)
				  (cancel-url *paypal-cancel-url*)
				  (useraction *paypal-useraction*)
				  (currencycode *paypal-currencycode*)
                                  (sandbox t)
                                  (hostname (if sandbox
                                              "www.sandbox.paypal.com"
                                              "www.paypal.com"))
				  &allow-other-keys)
  (dolist (key '(:return-url :cancel-url :useraction :currencycode :sandbox :hostname))
    (remf args key))
  (let* ((amt (format nil "~,2F" amount))
	 (res (apply #'request "SetExpressCheckout"
			       :returnurl return-url
			       :cancelurl cancel-url
			       :paymentrequest_0_amt amt
			       :paymentrequest_0_currencycode currencycode
			       :paymentrequest_0_paymentaction "Sale"
			       args))
	 (token (getf res :token)))
    (register-transaction token amt currencycode ip)
    (values
     (format nil "https://~A/webscr?cmd=_express-checkout&token=~A&useraction=~A"
	     hostname
	     (hunchentoot:url-encode token)
	     useraction)
     res)))

(defun get-express-checkout-info (token)
  (request "GetExpressCheckoutDetails" :token token))

(defun do-express-checkout (token)
  (let* ((txn (find-transaction token nil)))
    (if txn
        (destructuring-bind (amount currencycode ip time) txn
          (declare (ignore ip time))
          (let* ((response (request "GetExpressCheckoutDetails" :token token))
                 (payerid (getf response :payerid))
                 (result (request "DoExpressCheckoutPayment"
                                  :token token
                                  :payerid payerid
                                  ;; amt and currencycode are not returned by GetExpressCheckoutDetails 
                                  :paymentrequest_0_amt amount
                                  :paymentrequest_0_currencycode currencycode 
                                  :paymentrequest_0_paymentaction "Sale"))
                 (success-p (string-equal "Success" (getf result :paymentinfo_0_ack))))
            (when success-p
              (unregister-transaction token))
	    (values result response))))))

(defun get-and-do-express-checkout (success failure)
  (with-output-to-string (*standard-output*)
    (let* ((token (hunchentoot:get-parameter "token"))
           (txn (find-transaction token nil)))
      (if txn
        (destructuring-bind (amount currencycode ip time) txn
          (declare (ignore ip time))
          (let* ((response (request "GetExpressCheckoutDetails" :token token))
                 (payerid (getf response :payerid))
                 (result (request "DoExpressCheckoutPayment"
                                  :token token
                                  :payerid payerid
                                  ;; amt and currencycode are not returned by GetExpressCheckoutDetails 
                                  :paymentrequest_0_amt amount
                                  :paymentrequest_0_currencycode currencycode 
                                  :paymentrequest_0_paymentaction "Sale"))
                 (success-p (string-equal "Success" (getf result :paymentinfo_0_ack))))
            (when success-p
              (unregister-transaction token))
            (if success-p 
                (funcall success :amount amount :currencycode currencycode :token token :result result) 
                (funcall failure))))
        (funcall failure)))))

