//
//  CameraScannerViewController.swift
//  WeScan
//
//  Created by Boris Emorine on 2/12/18.
//  Copyright © 2018 WeTransfer. All rights reserved.
//

import UIKit
import AVFoundation

/// Simple camera scanner view controller that can be used standalone
final class CameraScannerViewController: UIViewController {
    
    /// Rectangle detection configuration parameters
    private let minimumAspectRatio: Float
    private let maximumAspectRatio: Float
    private let minimumConfidence: Float
    private let maximumObservations: Int
    private let minimumSize: Float
    private let quadratureTolerance: Float
    private let preferredCameraType: CameraType
    private let macroModeEnabled: Bool
    
    private var captureSessionManager: CaptureSessionManager?
    private let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    
    /// The view that draws the detected rectangles.
    private let quadView = QuadrilateralView()
    
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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor.black
        setupViews()
        setupConstraints()
        
        captureSessionManager = CaptureSessionManager(
            videoPreviewLayer: videoPreviewLayer, 
            delegate: self,
            minimumAspectRatio: minimumAspectRatio,
            maximumAspectRatio: maximumAspectRatio,
            minimumConfidence: minimumConfidence,
            maximumObservations: maximumObservations,
            minimumSize: minimumSize,
            quadratureTolerance: quadratureTolerance,
            preferredCameraType: preferredCameraType,
            macroModeEnabled: macroModeEnabled
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        
        CaptureSession.current.isEditing = false
        quadView.removeQuadrilateral()
        captureSessionManager?.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoPreviewLayer.frame = view.layer.bounds
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        captureSessionManager?.stop()
    }
    
    // MARK: - Setup
    
    private func setupViews() {
        view.layer.addSublayer(videoPreviewLayer)
        quadView.translatesAutoresizingMaskIntoConstraints = false
        quadView.editable = false
        view.addSubview(quadView)
    }
    
    private func setupConstraints() {
        let quadViewConstraints = [
            quadView.topAnchor.constraint(equalTo: view.topAnchor),
            view.bottomAnchor.constraint(equalTo: quadView.bottomAnchor),
            view.trailingAnchor.constraint(equalTo: quadView.trailingAnchor),
            quadView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        ]
        
        NSLayoutConstraint.activate(quadViewConstraints)
    }
    
    // MARK: - Status Bar
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
}

// MARK: - RectangleDetectionDelegateProtocol

extension CameraScannerViewController: RectangleDetectionDelegateProtocol {
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didFailWithError error: Error) {
        // Handle capture session errors
        print("CameraScannerViewController error: \(error.localizedDescription)")
    }
    
    func didStartCapturingPicture(for captureSessionManager: CaptureSessionManager) {
        // Handle start of picture capture
    }
    
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didCapturePicture picture: UIImage, withQuad quad: Quadrilateral?) {
        // Handle captured picture with detected quadrilateral
    }
    
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didDetectQuad quad: Quadrilateral?, _ imageSize: CGSize) {
        guard let quad = quad else {
            // If no quad is detected, remove the displayed rectangle
            quadView.removeQuadrilateral()
            return
        }
        
        let portraitImageSize = CGSize(
            width: min(imageSize.width, imageSize.height),
            height: max(imageSize.width, imageSize.height)
        )
        
        let scaleTransform = CGAffineTransform.scaleTransform(
            forSize: portraitImageSize,
            aspectFillInSize: quadView.bounds.size
        )
        let scaledImageSize = imageSize.applying(scaleTransform)
        
        let rotationTransform = CGAffineTransform(rotationAngle: CGFloat.pi / 2.0)
        
        let imageBounds = CGRect(
            origin: .zero,
            size: scaledImageSize
        ).applying(rotationTransform)
        
        let translationTransform = CGAffineTransform.translateTransform(
            fromCenterOfRect: imageBounds,
            toCenterOfRect: quadView.bounds
        )
        
        let transforms = [scaleTransform, rotationTransform, translationTransform]
        
        let transformedQuad = quad.applyTransforms(transforms)
        
        quadView.drawQuadrilateral(quad: transformedQuad, animated: true)
    }
}
