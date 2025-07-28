//
//  ScannerViewController.swift
//  WeScan
//
//  Created by Boris Emorine on 2/8/18.
//  Copyright © 2018 WeTransfer. All rights reserved.
//
//  swiftlint:disable line_length

import AVFoundation
import UIKit

/// The `ScannerViewController` offers an interface to give feedback to the user regarding quadrilaterals that are detected. It also gives the user the opportunity to capture an image with a detected rectangle.
public final class ScannerViewController: UIViewController {

    /// Whether flash is enabled
    private var flashEnabled = false

    /// The original bar style that was set by the host app
    private var originalBarStyle: UIBarStyle?
    
    /// Rectangle detection configuration parameters
    private let minimumAspectRatio: Float
    private let maximumAspectRatio: Float
    private let minimumConfidence: Float
    private let maximumObservations: Int
    private let minimumSize: Float
    private let quadratureTolerance: Float
    private let preferredCameraType: CameraType
    private let macroModeEnabled: Bool

    private lazy var shutterButton: ShutterButton = {
        let button = ShutterButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(captureImage(_:)), for: .touchUpInside)
        return button
    }()

    private lazy var cancelButton: UIButton = {
        let button = UIButton()
        button.setTitle(NSLocalizedString("wescan.scanning.cancel", tableName: nil, bundle: Bundle(for: ScannerViewController.self), value: "Cancel", comment: "The cancel button"), for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelImageScannerController), for: .touchUpInside)
        return button
    }()



    private lazy var flashButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: UIImage(systemName: "bolt.fill"), 
            style: .plain, 
            target: self, 
            action: #selector(toggleFlash)
        )
        return button
    }()

    private lazy var autoScanButton: UIBarButtonItem = {
        let button = UIBarButtonItem(
            title: NSLocalizedString("wescan.scanning.auto", tableName: nil, bundle: Bundle(for: ScannerViewController.self), value: "Auto", comment: "The auto button state"),
            style: .plain, 
            target: self, 
            action: #selector(toggleAutoScan)
        )
        return button
    }()

    private lazy var activityIndicator: UIActivityIndicatorView = {
        let activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        return activityIndicator
    }()

    private var captureSessionManager: CaptureSessionManager?
    private let videoPreviewLayer = AVCaptureVideoPreviewLayer()

    /// The view that shows the focus rectangle (when the user taps to focus, similar to the Camera app)
    private var focusRectangle: FocusRectangleView!

    /// The view that draws the detected rectangles.
    private let quadView = QuadrilateralView()

    // MARK: - Life Cycle
    
    public init(minimumAspectRatio: Float = 0.3,
                maximumAspectRatio: Float = 1.0,
                minimumConfidence: Float = 0.8,
                maximumObservations: Int = 1,
                minimumSize: Float = 0.2,
                quadratureTolerance: Float = 30.0,
                preferredCameraType: CameraType = .auto,
                macroModeEnabled: Bool = false) {
        self.minimumAspectRatio = minimumAspectRatio
        self.maximumAspectRatio = maximumAspectRatio
        self.minimumConfidence = minimumConfidence
        self.maximumObservations = maximumObservations
        self.minimumSize = minimumSize
        self.quadratureTolerance = quadratureTolerance
        self.preferredCameraType = preferredCameraType
        self.macroModeEnabled = macroModeEnabled
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        self.minimumAspectRatio = 0.3
        self.maximumAspectRatio = 1.0
        self.minimumConfidence = 0.8
        self.maximumObservations = 1
        self.minimumSize = 0.2
        self.quadratureTolerance = 30.0
        self.preferredCameraType = .auto
        self.macroModeEnabled = false
        super.init(coder: coder)
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        
        title = NSLocalizedString("wescan.scanning.title", tableName: nil, bundle: Bundle(for: ScannerViewController.self), value: "Scanning", comment: "The title of the ScannerViewController")
        view.backgroundColor = UIColor.black

        setupViews()
        setupConstraints()

        captureSessionManager = CaptureSessionManager(videoPreviewLayer: videoPreviewLayer, delegate: self, minimumAspectRatio: minimumAspectRatio, maximumAspectRatio: maximumAspectRatio, minimumConfidence: minimumConfidence, maximumObservations: maximumObservations, minimumSize: minimumSize, quadratureTolerance: quadratureTolerance, preferredCameraType: preferredCameraType, macroModeEnabled: macroModeEnabled)

        originalBarStyle = navigationController?.navigationBar.barStyle

        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: Notification.Name.AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()

        CaptureSession.current.isEditing = false
        quadView.removeQuadrilateral()
        captureSessionManager?.start()
        UIApplication.shared.isIdleTimerDisabled = true

        navigationController?.navigationBar.barStyle = .blackTranslucent
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        videoPreviewLayer.frame = view.layer.bounds
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false

        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.barStyle = originalBarStyle ?? .default
        captureSessionManager?.stop()
        guard let device = AVCaptureDevice.default(for: AVMediaType.video) else { return }
        if device.torchMode == .on {
            toggleFlash()
        }
    }

    // MARK: - Setups

    private func setupViews() {
        view.backgroundColor = .darkGray
        view.layer.addSublayer(videoPreviewLayer)
        quadView.translatesAutoresizingMaskIntoConstraints = false
        quadView.editable = false
        view.addSubview(quadView)
        view.addSubview(cancelButton)
        view.addSubview(shutterButton)
        view.addSubview(activityIndicator)
    }

    private func setupNavigationBar() {
        navigationItem.setLeftBarButton(flashButton, animated: false)
        navigationItem.setRightBarButton(autoScanButton, animated: false)

        if UIImagePickerController.isFlashAvailable(for: .rear) == false {
            let flashOffImage = UIImage(systemName: "bolt.slash.fill", named: "flashUnavailable", in: Bundle(for: ScannerViewController.self), compatibleWith: nil)
            let disabledFlashButton = UIBarButtonItem(image: flashOffImage, style: .plain, target: self, action: #selector(toggleFlash))
            disabledFlashButton.tintColor = UIColor.lightGray
            navigationItem.setLeftBarButton(disabledFlashButton, animated: false)
        }
    }

    private func setupConstraints() {
        var quadViewConstraints = [NSLayoutConstraint]()
        var cancelButtonConstraints = [NSLayoutConstraint]()
        var shutterButtonConstraints = [NSLayoutConstraint]()
        var activityIndicatorConstraints = [NSLayoutConstraint]()

        quadViewConstraints = [
            quadView.topAnchor.constraint(equalTo: view.topAnchor),
            view.bottomAnchor.constraint(equalTo: quadView.bottomAnchor),
            view.trailingAnchor.constraint(equalTo: quadView.trailingAnchor),
            quadView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        ]

        shutterButtonConstraints = [
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.widthAnchor.constraint(equalToConstant: 65.0),
            shutterButton.heightAnchor.constraint(equalToConstant: 65.0)
        ]

        activityIndicatorConstraints = [
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ]

        if #available(iOS 11.0, *) {
            cancelButtonConstraints = [
                cancelButton.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor, constant: 24.0),
                view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: (65.0 / 2) - 10.0)
            ]

            let shutterButtonBottomConstraint = view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: shutterButton.bottomAnchor, constant: 8.0)
            shutterButtonConstraints.append(shutterButtonBottomConstraint)
        } else {
            cancelButtonConstraints = [
                cancelButton.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 24.0),
                view.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: (65.0 / 2) - 10.0)
            ]

            let shutterButtonBottomConstraint = view.bottomAnchor.constraint(equalTo: shutterButton.bottomAnchor, constant: 8.0)
            shutterButtonConstraints.append(shutterButtonBottomConstraint)
        }

        NSLayoutConstraint.activate(quadViewConstraints + cancelButtonConstraints + shutterButtonConstraints + activityIndicatorConstraints)
    }

    // MARK: - Tap to Focus

    /// Called when the AVCaptureDevice detects that the subject area has changed significantly. When it's called, we reset the focus so the camera is no longer out of focus.
    @objc private func subjectAreaDidChange() {
        /// Reset the focus and exposure back to automatic
        // Reset focus to auto using our capture session manager if available
        if let captureSessionManager = captureSessionManager {
            captureSessionManager.resetFocusToAuto()
        } else {
            // Fallback to old method for compatibility
            do {
                try CaptureSession.current.resetFocusToAuto()
            } catch {
                let error = ImageScannerControllerError.inputDevice
                guard let captureSessionManager else { return }
                captureSessionManager.delegate?.captureSessionManager(captureSessionManager, didFailWithError: error)
                return
            }
        }

        /// Remove the focus rectangle if one exists
        CaptureSession.current.removeFocusRectangleIfNeeded(focusRectangle, animated: true)
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        guard  let touch = touches.first else { return }
        let touchPoint = touch.location(in: view)
        let convertedTouchPoint: CGPoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: touchPoint)

        CaptureSession.current.removeFocusRectangleIfNeeded(focusRectangle, animated: false)

        focusRectangle = FocusRectangleView(touchPoint: touchPoint)
        view.addSubview(focusRectangle)

        // Set focus point using our capture session manager if available
        if let captureSessionManager = captureSessionManager {
            captureSessionManager.setFocusPointToTapPoint(convertedTouchPoint)
        } else {
            // Fallback to old method for compatibility
            do {
                try CaptureSession.current.setFocusPointToTapPoint(convertedTouchPoint)
            } catch {
                let error = ImageScannerControllerError.inputDevice
                guard let captureSessionManager else { return }
                captureSessionManager.delegate?.captureSessionManager(captureSessionManager, didFailWithError: error)
                return
            }
        }
    }

    // MARK: - Actions

    @objc private func captureImage(_ sender: UIButton) {
        (navigationController as? ImageScannerController)?.flashToBlack()
        shutterButton.isUserInteractionEnabled = false
        captureSessionManager?.capturePhoto()
    }

    @objc private func toggleAutoScan() {
        if CaptureSession.current.isAutoScanEnabled {
            CaptureSession.current.isAutoScanEnabled = false
            let manualButton = UIBarButtonItem(
                title: NSLocalizedString("wescan.scanning.manual", tableName: nil, bundle: Bundle(for: ScannerViewController.self), value: "Manual", comment: "The manual button state"),
                style: .plain,
                target: self,
                action: #selector(toggleAutoScan)
            )
            navigationItem.setRightBarButton(manualButton, animated: false)
        } else {
            CaptureSession.current.isAutoScanEnabled = true
            let autoButton = UIBarButtonItem(
                title: NSLocalizedString("wescan.scanning.auto", tableName: nil, bundle: Bundle(for: ScannerViewController.self), value: "Auto", comment: "The auto button state"),
                style: .plain,
                target: self,
                action: #selector(toggleAutoScan)
            )
            navigationItem.setRightBarButton(autoButton, animated: false)
        }
    }

    @objc private func toggleFlash() {
        let state = CaptureSession.current.toggleFlash()

        let flashImage = UIImage(systemName: "bolt.fill", named: "flash", in: Bundle(for: ScannerViewController.self), compatibleWith: nil)
        let flashOffImage = UIImage(systemName: "bolt.slash.fill", named: "flashUnavailable", in: Bundle(for: ScannerViewController.self), compatibleWith: nil)

        switch state {
        case .on:
            flashEnabled = true
            let flashOnButton = UIBarButtonItem(image: flashImage, style: .plain, target: self, action: #selector(toggleFlash))
            flashOnButton.tintColor = .yellow
            navigationItem.setLeftBarButton(flashOnButton, animated: false)
        case .off:
            flashEnabled = false
            let flashOffButton = UIBarButtonItem(image: flashImage, style: .plain, target: self, action: #selector(toggleFlash))
            flashOffButton.tintColor = .white
            navigationItem.setLeftBarButton(flashOffButton, animated: false)
        case .unknown, .unavailable:
            flashEnabled = false
            let flashUnavailableButton = UIBarButtonItem(image: flashOffImage, style: .plain, target: self, action: #selector(toggleFlash))
            flashUnavailableButton.tintColor = UIColor.lightGray
            navigationItem.setLeftBarButton(flashUnavailableButton, animated: false)
        }
    }

    @objc private func cancelImageScannerController() {
        guard let imageScannerController = navigationController as? ImageScannerController else { return }
        imageScannerController.imageScannerDelegate?.imageScannerControllerDidCancel(imageScannerController)
    }

}

extension ScannerViewController: RectangleDetectionDelegateProtocol {
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didFailWithError error: Error) {

        activityIndicator.stopAnimating()
        shutterButton.isUserInteractionEnabled = true

        guard let imageScannerController = navigationController as? ImageScannerController else { return }
        imageScannerController.imageScannerDelegate?.imageScannerController(imageScannerController, didFailWithError: error)
    }

    func didStartCapturingPicture(for captureSessionManager: CaptureSessionManager) {
        activityIndicator.startAnimating()
        captureSessionManager.stop()
        shutterButton.isUserInteractionEnabled = false
    }

    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didCapturePicture picture: UIImage, withQuad quad: Quadrilateral?) {
        activityIndicator.stopAnimating()

        let editVC = EditScanViewController(image: picture, quad: quad)
        navigationController?.pushViewController(editVC, animated: false)

        shutterButton.isUserInteractionEnabled = true
    }

    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didDetectQuad quad: Quadrilateral?, _ imageSize: CGSize) {
        guard let quad else {
            // If no quad has been detected, we remove the currently displayed on on the quadView.
            quadView.removeQuadrilateral()
            return
        }

        let portraitImageSize = CGSize(width: imageSize.height, height: imageSize.width)

        let scaleTransform = CGAffineTransform.scaleTransform(forSize: portraitImageSize, aspectFillInSize: quadView.bounds.size)
        let scaledImageSize = imageSize.applying(scaleTransform)

        let rotationTransform = CGAffineTransform(rotationAngle: CGFloat.pi / 2.0)

        let imageBounds = CGRect(origin: .zero, size: scaledImageSize).applying(rotationTransform)

        let translationTransform = CGAffineTransform.translateTransform(fromCenterOfRect: imageBounds, toCenterOfRect: quadView.bounds)

        let transforms = [scaleTransform, rotationTransform, translationTransform]

        let transformedQuad = quad.applyTransforms(transforms)

        quadView.drawQuadrilateral(quad: transformedQuad, animated: true)
    }

}
